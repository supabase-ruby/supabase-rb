# frozen_string_literal: true

require_relative "errors"
require_relative "message"
require_relative "presence"
require_relative "push"
require_relative "timer"
require_relative "types"

module Supabase
  module Realtime
    # A topic subscription on a shared Socket connection. Each Channel:
    # - tracks its own lifecycle state (closed/joining/joined/leaving/errored)
    # - holds the listener callbacks for postgres changes / broadcast / presence / system
    # - dispatches inbound messages from the Client to those callbacks
    # - owns its Presence sync state
    #
    # Should be constructed via {Client#channel}, not directly.
    class Channel
      attr_reader :topic, :params, :state, :join_push, :presence, :pending_pushes, :rejoin_timer

      def initialize(topic, params: nil, socket: nil)
        @topic   = topic
        @params  = params || default_params
        @socket  = socket
        @state   = Types::ChannelStates::CLOSED
        @joined_once = false
        @presence = Presence.new

        @broadcast_callbacks        = []   # [{ event:, callback: }]
        @postgres_changes_callbacks = []   # [{ event:, schema:, table:, filter:, callback: }]
        @system_callbacks           = []
        @close_callbacks            = []
        @error_callbacks            = []

        @pending_pushes = {} # ref => Push, for matching phx_reply
        @push_buffer    = [] # outbound pushes queued while not yet joined

        @join_push = Push.new(self, Types::ChannelEvents::JOIN, @params)
        @subscribe_callback = nil

        @rejoin_timer = Timer.new(
          callback: -> { rejoin if @joined_once && !leaving? && !closed? },
          backoff:  ->(tries) { [(2.0**tries), 60.0].min }
        )

        @join_push
          .receive(Types::AckStatus::OK)      { |p| on_join_ok(p) }
          .receive(Types::AckStatus::ERROR)   { |p| on_join_error(p) }
          .receive(Types::AckStatus::TIMEOUT) { |_| on_join_timeout }
      end

      # ----- State predicates -----

      def closed?;  @state == Types::ChannelStates::CLOSED;  end
      def errored?; @state == Types::ChannelStates::ERRORED; end
      def joined?;  @state == Types::ChannelStates::JOINED;  end
      def joining?; @state == Types::ChannelStates::JOINING; end
      def leaving?; @state == Types::ChannelStates::LEAVING; end

      # ----- Subscription -----

      # Start the join handshake. Optional block fires when the join completes,
      # receiving the SubscribeStates value (SUBSCRIBED / CHANNEL_ERROR / TIMED_OUT).
      def subscribe(&block)
        raise Errors::AlreadyJoinedError, "subscribe can only be called once per channel" if @joined_once

        @joined_once = true
        @subscribe_callback = block
        @state = Types::ChannelStates::JOINING

        inject_postgres_changes_bindings
        @join_push.instance_variable_set(:@ref, @socket&.next_ref)
        # Make subscribe a one-call entry point: if the caller hasn't already
        # connected the underlying transport, open it now so the join frame
        # actually reaches the wire instead of being held forever in the
        # Client#send_buffer. Matches supabase-py's `channel.subscribe()` ergonomics.
        @socket.connect if @socket && !@socket.connected?
        send_push(@join_push, register_pending: true)
        self
      end

      # Re-issue the join push without resetting @joined_once. Used by the
      # client after a socket reconnect to restore channel subscriptions.
      def rejoin
        return unless @joined_once

        @state = Types::ChannelStates::JOINING
        inject_postgres_changes_bindings
        @join_push.instance_variable_set(:@ref, @socket&.next_ref)
        @join_push.instance_variable_set(:@received_status, nil)
        send_push(@join_push, register_pending: true)
        self
      end

      # Tear down the subscription with a phx_leave push. State stays in LEAVING
      # until the server acks (or errors / times out) — mirrors phoenix.js and
      # supabase-py so a fast unsubscribe→resubscribe cycle doesn't race with the
      # server's reply for the previous join.
      def unsubscribe
        return self if closed?

        @state = Types::ChannelStates::LEAVING
        ref = @socket&.next_ref
        leave_push = Push.new(self, Types::ChannelEvents::LEAVE, {}, ref: ref)

        leave_push
          .receive(Types::AckStatus::OK)      { |_| on_leave_ack }
          .receive(Types::AckStatus::ERROR)   { |_| on_leave_ack }
          .receive(Types::AckStatus::TIMEOUT) { |_| on_leave_ack }

        send_push(leave_push, register_pending: true)
        self
      end

      # ----- Listener registration -----

      # Register a postgres-changes listener. event may be "INSERT", "UPDATE",
      # "DELETE", or "*" for all three. schema/table/filter narrow which rows
      # fire the callback. Returns self so calls chain.
      def on_postgres_changes(event, schema: nil, table: nil, filter: nil, &block)
        unless %w[INSERT UPDATE DELETE *].include?(event)
          raise ArgumentError, "postgres_changes event must be INSERT/UPDATE/DELETE/*"
        end

        @postgres_changes_callbacks << {
          event: event, schema: schema, table: table, filter: filter, callback: block
        }
        self
      end

      def on_broadcast(event, &block)
        @broadcast_callbacks << { event: event, callback: block }
        self
      end

      def on_system(&block)
        @system_callbacks << block
        self
      end

      def on_close(&block)
        @close_callbacks << block
        self
      end

      def on_error(&block)
        @error_callbacks << block
        self
      end

      # Convenience wrappers around the underlying `channel.presence` object,
      # matching supabase-py's `channel.on_presence_sync/join/leave` API. If
      # called after the channel is already joined, the channel resubscribes so
      # the server starts forwarding presence events (presence has to be enabled
      # in the join config — see #default_params).
      def on_presence_sync(&block)
        @presence.on_sync(&block)
        resubscribe_for_presence!
        self
      end

      def on_presence_join(&block)
        @presence.on_join(&block)
        resubscribe_for_presence!
        self
      end

      def on_presence_leave(&block)
        @presence.on_leave(&block)
        resubscribe_for_presence!
        self
      end

      # Shortcut for `channel.presence.state` so callers don't have to drill in.
      def presence_state
        @presence.state
      end

      # ----- Outbound -----

      # Send a custom broadcast message. The server will forward it to other
      # subscribers of the same topic.
      def send_broadcast(event, payload = {})
        push = Push.new(self,
                        Types::ChannelEvents::BROADCAST,
                        { "type" => "broadcast", "event" => event, "payload" => payload })
        send_push(push, register_pending: false)
        self
      end

      # Track the local user in the channel's presence state.
      def track(payload)
        push = Push.new(self,
                        Types::ChannelEvents::PRESENCE,
                        { "type" => "presence", "event" => "track", "payload" => payload })
        send_push(push, register_pending: false)
        self
      end

      def untrack
        push = Push.new(self,
                        Types::ChannelEvents::PRESENCE,
                        { "type" => "presence", "event" => "untrack" })
        send_push(push, register_pending: false)
        self
      end

      # Public low-level push for arbitrary Phoenix events. Mirrors
      # `supabase-py`'s `channel.push(event, payload, timeout)`. Returns the
      # {Push} instance so callers can attach receive() handlers and observe the
      # reply / timeout. Raises if called before {#subscribe}.
      def push_event(event, payload = {}, timeout: nil)
        unless @joined_once
          raise Errors::RealtimeError,
                "tried to push '#{event}' to '#{@topic}' before joining. Call subscribe() first."
        end

        ref = @socket&.next_ref
        push = Push.new(self, event, payload, ref: ref, timeout: timeout || Types::DEFAULT_TIMEOUT_SECONDS)
        send_push(push, register_pending: true)
        push
      end

      # ----- Inbound dispatch (called by Client) -----

      # Route a parsed Message to the appropriate listeners. Returns true if the
      # message belonged to this channel, false otherwise (so the Client knows
      # whether to drop it).
      def dispatch(message)
        return false unless message.topic == @topic

        case message.event
        when Types::ChannelEvents::REPLY
          dispatch_reply(message)
        when Types::ChannelEvents::POSTGRES_CHANGES
          dispatch_postgres_changes(message)
        when Types::ChannelEvents::BROADCAST
          dispatch_broadcast(message)
        when Types::ChannelEvents::PRESENCE_STATE
          @presence.sync_state(message.payload)
        when Types::ChannelEvents::PRESENCE_DIFF
          @presence.sync_diff(message.payload)
        when Types::ChannelEvents::SYSTEM
          @system_callbacks.each { |cb| cb.call(message.payload) }
        when Types::ChannelEvents::CLOSE
          @state = Types::ChannelStates::CLOSED
          @close_callbacks.each { |cb| cb.call(message.payload) }
        when Types::ChannelEvents::ERROR
          @state = Types::ChannelStates::ERRORED
          @error_callbacks.each { |cb| cb.call(message.payload) }
        end

        true
      end

      private

      def default_params
        {
          "config" => {
            "broadcast" => { "ack" => false, "self" => false },
            "presence"  => { "key" => "", "enabled" => false },
            "private"   => false
          }
        }
      end

      # Mirrors phoenix.js / supabase-py: every registered on_postgres_changes
      # listener is serialized into config.postgres_changes on the join payload
      # so the server filters before sending, instead of shipping every change
      # for the topic and forcing the client to drop most of them. Also flips
      # config.presence.enabled when any presence callback is attached, so the
      # server starts emitting presence_state/diff frames. Finally, pulls the
      # current socket access_token onto config.access_token so RLS sees the
      # caller's JWT — private channels reject the join otherwise. The token
      # source is identical to what set_auth rotates (single source of truth).
      def inject_postgres_changes_bindings
        config = (@join_push.payload["config"] ||= {})
        config["postgres_changes"] = @postgres_changes_callbacks.map do |binding|
          entry = { "event" => binding[:event] }
          entry["schema"] = binding[:schema] if binding[:schema]
          entry["table"]  = binding[:table]  if binding[:table]
          entry["filter"] = binding[:filter] if binding[:filter]
          entry
        end

        presence_cfg = (config["presence"] ||= {})
        presence_cfg["enabled"] = true if @presence.any_callbacks?

        config["access_token"] = @socket&.access_token
      end

      # If a presence callback is added after the channel is already joined,
      # the server's join config is stale (presence.enabled is still false), so
      # we resubscribe to send a fresh join payload. Matches py's _resubscribe.
      def resubscribe_for_presence!
        return unless joined?

        unsubscribe
        @joined_once = false
        @join_push.instance_variable_set(:@received_status, nil)
        subscribe(&@subscribe_callback)
      end

      def send_push(push, register_pending:)
        message = Message.new(
          event:    push.event,
          topic:    @topic,
          payload:  push.payload,
          ref:      push.ref,
          join_ref: @join_push.ref
        )

        if can_send?(push)
          if register_pending && push.ref
            @pending_pushes[push.ref] = push
            # Arm the timeout only once the push is actually on the wire — if it
            # gets buffered (channel not yet joined) we leave it untimed until
            # the buffer is flushed.
            push.start_timeout
          end
          @socket&.push(message)
        else
          @push_buffer << [push, register_pending]
        end
      end

      def remove_pending(ref)
        @pending_pushes.delete(ref)
      end

      # The join push flushes while joining; the leave push flushes while leaving.
      # Everything else (broadcasts, presence, custom pushes) only sends once
      # joined — calls made before subscribe() / between subscribe() and the
      # phx_reply ack are buffered and replayed by flush_push_buffer on JOINED.
      def can_send?(push)
        return joining? || joined? if push.equal?(@join_push)
        return leaving? if push.event == Types::ChannelEvents::LEAVE

        joined?
      end

      def dispatch_reply(message)
        ref = message.ref
        push = @pending_pushes.delete(ref)
        return unless push

        push.resolve(
          status:  message.payload["status"],
          payload: message.payload["response"] || message.payload
        )
      end

      def dispatch_postgres_changes(message)
        # Payload shape: { "data" => { "type" => "INSERT", "schema" => "public", "table" => "users", ... }, "ids" => [...] }
        data = message.payload["data"] || {}
        change_type = data["type"]
        schema      = data["schema"]
        table       = data["table"]
        ids         = message.payload["ids"]

        @postgres_changes_callbacks.each do |binding|
          next unless binding[:event] == change_type || binding[:event] == "*"
          next if binding[:schema] && binding[:schema] != schema
          next if binding[:table]  && binding[:table]  != table
          # Server-side binding-id routing: once on_join_ok has recorded the
          # server-assigned :id, an inbound frame's payload.ids tells us which
          # bindings the server intended to fire. This is how two bindings on
          # the same (schema, table) but different :filter get demultiplexed —
          # without it both would fire on every change. Before the join-ack
          # (no :id yet) we fall through and the legacy event/schema/table
          # filtering remains the sole gate.
          next if binding[:id] && ids.is_a?(Array) && !ids.include?(binding[:id])

          binding[:callback].call(message.payload)
        end
      end

      def dispatch_broadcast(message)
        event = message.payload["event"]
        @broadcast_callbacks.each do |binding|
          binding[:callback].call(message.payload) if binding[:event] == event
        end
      end

      def on_join_ok(payload = nil)
        # phoenix replies for postgres_changes echo back the bindings the server
        # actually registered. Compare them index-wise with our local callbacks:
        # if any client binding doesn't match the server's, the subscription is
        # silently going to miss events — abort the subscription and surface a
        # CHANNEL_ERROR so the caller can react instead of waiting forever for
        # rows that will never arrive.
        server_postgres_changes = payload.is_a?(Hash) ? payload["postgres_changes"] : nil

        if server_postgres_changes && !@postgres_changes_callbacks.empty?
          new_bindings = []
          mismatch = false

          @postgres_changes_callbacks.each_with_index do |binding, i|
            server_binding = server_postgres_changes[i]

            if server_binding &&
               server_binding["event"] == binding[:event] &&
               server_binding["schema"] == binding[:schema] &&
               server_binding["table"] == binding[:table] &&
               server_binding["filter"] == binding[:filter]
              new_bindings << binding.merge(id: server_binding["id"])
            else
              mismatch = true
              break
            end
          end

          if mismatch
            unsubscribe
            err = Errors::RealtimeError.new(
              "mismatch between server and client bindings for postgres changes"
            )
            @subscribe_callback&.call(Types::SubscribeStates::CHANNEL_ERROR, err)
            return
          end

          @postgres_changes_callbacks = new_bindings
        end

        @state = Types::ChannelStates::JOINED
        @rejoin_timer.reset
        flush_push_buffer
        @subscribe_callback&.call(Types::SubscribeStates::SUBSCRIBED, nil)
      end

      def on_join_error(payload)
        @state = Types::ChannelStates::ERRORED
        @rejoin_timer.schedule_timeout
        @subscribe_callback&.call(Types::SubscribeStates::CHANNEL_ERROR, payload)
      end

      def on_join_timeout
        @state = Types::ChannelStates::ERRORED
        @rejoin_timer.schedule_timeout
        @subscribe_callback&.call(Types::SubscribeStates::TIMED_OUT, nil)
      end

      def flush_push_buffer
        buffered = @push_buffer
        @push_buffer = []
        buffered.each { |push, register_pending| send_push(push, register_pending: register_pending) }
      end

      def on_leave_ack
        @state = Types::ChannelStates::CLOSED
        @close_callbacks.each { |cb| cb.call({}) }
      end
    end
  end
end
