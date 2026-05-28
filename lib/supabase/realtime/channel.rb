# frozen_string_literal: true

require_relative "errors"
require_relative "message"
require_relative "presence"
require_relative "push"
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
      attr_reader :topic, :params, :state, :join_push, :presence, :pending_pushes

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

        @join_push
          .receive(Types::AckStatus::OK)      { |_| on_join_ok }
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

        @join_push.instance_variable_set(:@ref, @socket&.next_ref)
        send_push(@join_push, register_pending: true)
        self
      end

      # Tear down the subscription with a phx_leave push.
      def unsubscribe
        @state = Types::ChannelStates::LEAVING
        ref = @socket&.next_ref
        leave_push = Push.new(self, Types::ChannelEvents::LEAVE, {}, ref: ref)
        send_push(leave_push, register_pending: false)
        @state = Types::ChannelStates::CLOSED
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

      def send_push(push, register_pending:)
        message = Message.new(
          event:    push.event,
          topic:    @topic,
          payload:  push.payload,
          ref:      push.ref,
          join_ref: @join_push.ref
        )

        if can_send?
          @pending_pushes[push.ref] = push if register_pending && push.ref
          @socket&.push(message)
        else
          @push_buffer << [push, register_pending]
        end
      end

      def can_send?
        # The join push flushes while joining; the leave push flushes while leaving.
        # Everything else (broadcasts, presence, custom pushes) only sends once joined.
        [
          Types::ChannelStates::JOINED,
          Types::ChannelStates::JOINING,
          Types::ChannelStates::LEAVING
        ].include?(@state)
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

        @postgres_changes_callbacks.each do |binding|
          next unless binding[:event] == change_type || binding[:event] == "*"
          next if binding[:schema] && binding[:schema] != schema
          next if binding[:table]  && binding[:table]  != table

          binding[:callback].call(message.payload)
        end
      end

      def dispatch_broadcast(message)
        event = message.payload["event"]
        @broadcast_callbacks.each do |binding|
          binding[:callback].call(message.payload) if binding[:event] == event
        end
      end

      def on_join_ok
        @state = Types::ChannelStates::JOINED
        flush_push_buffer
        @subscribe_callback&.call(Types::SubscribeStates::SUBSCRIBED, nil)
      end

      def on_join_error(payload)
        @state = Types::ChannelStates::ERRORED
        @subscribe_callback&.call(Types::SubscribeStates::CHANNEL_ERROR, payload)
      end

      def on_join_timeout
        @state = Types::ChannelStates::ERRORED
        @subscribe_callback&.call(Types::SubscribeStates::TIMED_OUT, nil)
      end

      def flush_push_buffer
        buffered = @push_buffer
        @push_buffer = []
        buffered.each { |push, register_pending| send_push(push, register_pending: register_pending) }
      end
    end
  end
end
