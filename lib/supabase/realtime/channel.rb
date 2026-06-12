# frozen_string_literal: true

require_relative "callback_safety"
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
        @presence = Presence.new(logger: logger)

        @broadcast_callbacks        = []   # [{ event:, callback: }]
        @postgres_changes_callbacks = []   # [{ event:, schema:, table:, filter:, callback: }]
        @system_callbacks           = []
        @close_callbacks            = []
        @error_callbacks            = []

        @pending_pushes = {} # ref => Push, for matching phx_reply
        @push_buffer    = [] # outbound pushes queued while not yet joined

        @join_push = Push.new(self, Types::ChannelEvents::JOIN, @params)
        @subscribe_callback = nil

        # py rejoin uses `lambda tries: 2**tries` with no cap
        # (`realtime/_async/channel.py:109-111`). Timer (US-006) bumps `tries`
        # before invoking this lambda with `tries + 1`, so the curve for the
        # first five attempts is 4, 8, 16, 32, 64 s — identical to py.
        @rejoin_timer = Timer.new(
          callback: -> { rejoin if @joined_once && !leaving? && !closed? },
          backoff:  ->(tries) { 2.0**tries }
        )

        @join_push
          .receive(Types::AckStatus::OK)      { |p| on_join_ok(p) }
          .receive(Types::AckStatus::ERROR)   { |p| on_join_error(p) }
          .receive(Types::AckStatus::TIMEOUT) { |_| on_join_timeout }
      end

      # Logger used by {CallbackSafety} when a user callback raises. Resolved
      # lazily from the realtime client (`@socket` in this class is the
      # {Realtime::Client}, which exposes its injected logger via
      # `Client#logger`). When the underlying transport doesn't carry a logger
      # (e.g. tests that pass a bare {TestSocket} as `socket:`), `safe` falls
      # through to `Kernel#warn`.
      def logger
        @socket.respond_to?(:logger) ? @socket.logger : nil
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
        # Make subscribe a one-call entry point. If the socket is already open,
        # send the join now. If it isn't, just (idempotently) open it — the
        # client's rejoin_channels fires on socket-open and (re)sends the join
        # exactly once. The previous version sent/buffered the join here AND let
        # rejoin_channels re-send it on open, so a subscribe-before-open issued
        # a DUPLICATE join; the server phx_closed the extra one, which (with the
        # registry-removal fix) tore the channel down and broke delivery. Caught
        # by the live integration suite, not the mocked specs.
        if @socket && !@socket.connected?
          @socket.connect
        else
          send_join_push
        end
        self
      end

      # Re-issue the join push without resetting @joined_once. Used by the
      # client after a socket reconnect to restore channel subscriptions, and by
      # the rejoin timer after a join error.
      def rejoin
        return unless @joined_once

        @state = Types::ChannelStates::JOINING
        inject_postgres_changes_bindings
        send_join_push
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

      # Push the rotated access_token to the server for this channel. Called by
      # {Client#set_auth} for every joined channel, mirroring supabase-py
      # (client.py:335-337): `await channel.push(ChannelEvents.access_token,
      # {"access_token": token})`. Routing through the normal push path means the
      # frame is buffered (not dropped) when the socket is momentarily offline,
      # matching py's `channel.push` buffering — the prior version only sent when
      # `connected?` and silently lost the rotation otherwise.
      def push_access_token(token)
        return unless @joined_once

        ref  = @socket&.next_ref
        push = Push.new(self,
                        Types::ChannelEvents::ACCESS_TOKEN,
                        { "access_token" => token },
                        ref: ref,
                        timeout: Types::DEFAULT_TIMEOUT_SECONDS)
        send_push(push, register_pending: true)
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
          # supabase-py routes system frames by status (channel.py:520-525): a
          # `status: "ok"` payload reaches the on_system callbacks; anything else
          # (e.g. a postgres_changes subscription failure reported via `system`)
          # is treated as a channel error → ERRORED + rejoin scheduled.
          if message.payload.is_a?(Hash) && message.payload["status"] == "error"
            trigger_channel_error(message.payload)
          else
            @system_callbacks.each do |cb|
              CallbackSafety.safe(logger, "system") { cb.call(message.payload) }
            end
          end
        when Types::ChannelEvents::CLOSE
          handle_channel_close(message.payload)
        when Types::ChannelEvents::ERROR
          trigger_channel_error(message.payload)
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
      # server starts emitting presence_state/diff frames.
      #
      # The access_token is placed at the ROOT of the join payload (a sibling of
      # "config"), and only when a token is actually present — matching
      # supabase-py's `channel.py` exactly:
      #
      #   config_payload = { "config": { ... } }
      #   if self.socket.access_token:
      #       config_payload["access_token"] = self.socket.access_token
      #
      # The server / Phoenix gateway reads `payload.access_token`, NOT
      # `payload.config.access_token`. Nesting it under config (as a prior
      # version of this port did) meant the caller's JWT never reached RLS and
      # private channels authorized with the URL apikey only. The token source is
      # the same field set_auth rotates (Client#access_token) — single source of
      # truth. On rejoin the payload hash is reused, so an explicitly-cleared
      # token must delete the stale key rather than leave it behind.
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

        token = @socket&.access_token
        if token
          @join_push.payload["access_token"] = token
        else
          @join_push.payload.delete("access_token")
        end
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

      # Put the join push on the wire — but only when the socket is actually
      # open. When it isn't, the join is intentionally NOT sent or buffered here:
      # the client's rejoin_channels re-sends it the moment the socket opens, and
      # sending/buffering it here too would duplicate the join (the server then
      # phx_closes the extra one). Assigns a fresh ref and clears any prior reply
      # status so a rejoin is matched to its own phx_reply.
      def send_join_push
        return unless @socket&.connected?

        @join_push.instance_variable_set(:@ref, @socket.next_ref)
        @join_push.instance_variable_set(:@received_status, nil)
        send_push(@join_push, register_pending: true)
      end

      def send_push(push, register_pending:)
        message = Message.new(
          event:    push.event,
          topic:    @topic,
          payload:  push.payload,
          ref:      push.ref,
          join_ref: @join_push.ref
        )

        if register_pending && push.ref
          @pending_pushes[push.ref] = push
          # Arm the timeout when the push is queued, not when it hits the wire
          # (py parity, channel.py:318-323): a push buffered on a channel that
          # never reaches JOINED must resolve TIMEOUT, not hang forever.
          push.start_timeout
        end

        if can_send?(push)
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
          # DIVERGES FROM PY/JS (intentional — see docs/PARITY.md D7): supabase-py
          # AND realtime-js demultiplex postgres_changes *solely* by the
          # server-assigned binding id (`id && ids.include?(id)`), so a binding
          # with no id fires for nothing. We instead filter client-side on
          # event/schema/table (above) and use the server id only as an
          # additional demux when present. This is more robust — events still
          # route correctly even if the server omits ids — at the cost of one
          # narrow edge case: two bindings on the SAME (schema, table, event)
          # differing only by `:filter`, while neither has a server id yet, will
          # both fire (we don't evaluate PostgREST `:filter` client-side). In the
          # normal flow on_join_ok records the ids on the join-ack, after which
          # this gate demuxes them correctly.
          next if binding[:id] && ids.is_a?(Array) && !ids.include?(binding[:id])

          CallbackSafety.safe(logger, "postgres_changes:#{binding[:event]}") do
            binding[:callback].call(message.payload)
          end
        end
      end

      def dispatch_broadcast(message)
        event = message.payload["event"]
        @broadcast_callbacks.each do |binding|
          next unless binding[:event] == event

          CallbackSafety.safe(logger, "broadcast:#{event}") do
            binding[:callback].call(message.payload)
          end
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
            fire_subscribe_callback(Types::SubscribeStates::CHANNEL_ERROR, err)
            return
          end

          @postgres_changes_callbacks = new_bindings
        end

        @state = Types::ChannelStates::JOINED
        @rejoin_timer.reset
        flush_push_buffer
        fire_subscribe_callback(Types::SubscribeStates::SUBSCRIBED, nil)
      end

      def on_join_error(payload)
        @state = Types::ChannelStates::ERRORED
        @rejoin_timer.schedule_timeout
        fire_subscribe_callback(Types::SubscribeStates::CHANNEL_ERROR, payload)
      end

      def on_join_timeout
        @state = Types::ChannelStates::ERRORED
        @rejoin_timer.schedule_timeout
        fire_subscribe_callback(Types::SubscribeStates::TIMED_OUT, nil)
      end

      def fire_subscribe_callback(state, error_or_payload)
        return unless @subscribe_callback

        CallbackSafety.safe(logger, "subscribe:#{state}") do
          @subscribe_callback.call(state, error_or_payload)
        end
      end

      def flush_push_buffer
        buffered = @push_buffer
        @push_buffer = []
        buffered.each do |push, register_pending|
          # A push that resolved while buffered (timed out waiting for the join)
          # must not go on the wire late — its caller already saw TIMEOUT.
          next if push.received_status

          send_push(push, register_pending: register_pending)
        end
      end

      def on_leave_ack
        handle_channel_close({})
      end

      # Channel teardown — mirrors supabase-py `channel.on_close`
      # (channel.py:134-138): cancel any pending rejoin, mark CLOSED, fire the
      # registered close listeners, and remove the channel from the owning
      # client's registry so a CLOSED channel no longer receives dispatched
      # frames and doesn't leak across a subscribe/unsubscribe churn cycle. The
      # registry removal is the fix for the prior leak where unsubscribed
      # channels stayed in `client.channels` forever and kept running
      # presence/broadcast dispatch.
      #
      # (Named distinctly from the public {#on_close} listener registrar, which
      # is an rb-only convenience with no py counterpart.)
      def handle_channel_close(payload = {})
        @rejoin_timer.reset
        @state = Types::ChannelStates::CLOSED
        @close_callbacks.each do |cb|
          CallbackSafety.safe(logger, "phx_close") { cb.call(payload) }
        end
        @socket._remove_channel(self) if @socket.respond_to?(:_remove_channel)
      end

      # Mirrors supabase-py `channel.on_error` (channel.py:140-146): a phx_error
      # frame, or a `system` frame with status "error", errors the channel and
      # schedules a rejoin with exponential backoff so a transient server-side
      # channel crash self-heals instead of staying dead until the whole socket
      # drops. No-op while LEAVING/CLOSED so a phx_error racing an unsubscribe
      # can't flip the channel back to ERRORED.
      def trigger_channel_error(payload)
        return if leaving? || closed?

        @state = Types::ChannelStates::ERRORED
        @rejoin_timer.schedule_timeout
        @error_callbacks.each do |cb|
          CallbackSafety.safe(logger, "phx_error") { cb.call(payload) }
        end
      end
    end
  end
end
