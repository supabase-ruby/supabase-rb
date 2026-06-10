# frozen_string_literal: true

require "json"
require "uri"

require_relative "channel"
require_relative "errors"
require_relative "message"
require_relative "transformers"
require_relative "types"
require_relative "version"

module Supabase
  module Realtime
    # Top-level Realtime client. Owns one {Socket}, multiplexes Channels onto it,
    # and dispatches inbound frames to whichever channel owns the topic.
    #
    # Bring your own {Socket} (e.g. websocket-client-simple adapter or async-websocket
    # adapter). For unit tests, pass a {TestSocket}. If no transport is supplied,
    # a default {Sockets::WebsocketClientSimple} adapter is constructed
    # automatically so `Supabase.create_client(...).realtime.channel(...).subscribe`
    # works out of the box.
    #
    #   client   = Supabase::Realtime::Client.new(
    #     url: "wss://project.supabase.co/realtime/v1",
    #     params: { apikey: key }
    #   )
    #
    #   channel = client.channel("realtime:public:users")
    #   channel.on_postgres_changes("*", schema: "public", table: "users") { |p| puts p }
    #   channel.subscribe
    class Client
      attr_reader :url, :params, :access_token, :channels, :socket, :timeout,
                  :heartbeat_interval, :auto_reconnect, :max_retries, :initial_backoff

      # @param url    [String] WebSocket endpoint (ws:// or wss://). Plain http(s) are upgraded.
      # @param params [Hash]   query-string params merged onto the URL (e.g. apikey/access_token)
      # @param transport [Socket, nil] inject your own transport. If nil, the production
      #   websocket-client-simple adapter is constructed from URL+params.
      # @param socket [Socket, nil] deprecated alias for `transport:` — kept for back compat.
      # @param timeout [Numeric] default per-push timeout (seconds)
      # @param heartbeat_interval [Numeric] seconds between automatic heartbeat pushes (0 disables)
      # @param auto_reconnect [Boolean] reconnect on unexpected socket close
      # @param max_retries [Integer] maximum reconnect attempts before giving up
      # @param initial_backoff [Numeric] seconds of delay before the first reconnect attempt;
      #   doubles each attempt up to a 60s cap (matches supabase-py)
      def initialize(url:, params: {}, transport: nil, socket: nil,
                     timeout: Types::DEFAULT_TIMEOUT_SECONDS,
                     heartbeat_interval: Types::DEFAULT_HEARTBEAT_INTERVAL_SECONDS,
                     auto_reconnect: true, max_retries: 5, initial_backoff: 1.0)
        unless Transformers.is_ws_url(url)
          raise ArgumentError,
                "Invalid Realtime URL #{url.inspect}: expected ws://, wss://, http://, or https://"
        end

        @url     = normalize_url(url, params)
        @params  = params
        @access_token = params[:access_token] || params["access_token"]
        @channels = []
        @socket   = transport || socket || build_default_transport
        @timeout  = timeout
        @ref      = 0

        @heartbeat_interval = heartbeat_interval
        @auto_reconnect     = auto_reconnect
        @max_retries        = max_retries
        @initial_backoff    = initial_backoff
        @heartbeat_thread   = nil
        @reconnect_thread   = nil
        @intentionally_closed = false
        @send_buffer        = [] # frames queued while no socket / not connected
        @send_buffer_mutex  = Mutex.new

        attach_socket if @socket
      end

      # Plug in a transport after construction (e.g. a websocket-client-simple wrapper).
      def use_socket(socket)
        @socket = socket
        attach_socket
        self
      end

      def connect
        unless @socket
          @socket = build_default_transport
          attach_socket
        end

        @intentionally_closed = false
        @socket.connect
        self
      end

      def disconnect
        @intentionally_closed = true
        stop_reconnect
        stop_heartbeat
        @socket&.close
        @channels.each { |ch| ch.instance_variable_set(:@state, Types::ChannelStates::CLOSED) }
        self
      end

      # Compat alias mirroring supabase-py's `client.close()`.
      alias close disconnect

      def connected?
        @socket && @socket.connected?
      end

      # Always returns a **new** Channel instance, matching supabase-py. The
      # client-side topic registry is a flat list, so multiple channels can
      # share a topic (each with its own join_ref / subscription lifecycle).
      # To look up an existing channel, walk `get_channels.find { |c| c.topic == ... }`.
      #
      # Topic names are auto-prefixed with `"realtime:"` to match supabase-py:
      # `client.channel("public:users")` reaches the same channel as
      # `client.channel("realtime:public:users")`. Pre-prefixed topics are left
      # alone so existing code keeps working.
      def channel(topic, params: nil)
        full_topic = topic.start_with?("realtime:") ? topic : "realtime:#{topic}"
        ch = Channel.new(full_topic, params: params, socket: self)
        @channels << ch
        ch
      end

      def get_channels
        @channels.dup
      end

      def remove_channel(channel)
        channel.unsubscribe
        @channels.delete(channel)
        @socket&.close if @channels.empty?
      end

      # Unsubscribe every tracked channel and clear the registry. Iterates over a
      # snapshot (`@channels.dup`) so a channel that removes itself during
      # `unsubscribe` doesn't shift the array mid-loop. Idempotent: a follow-up
      # call on an empty registry is a no-op.
      # @see supabase-py supabase/_sync/client.py:234
      def remove_all_channels
        @channels.dup.each { |ch| ch.unsubscribe }
        @channels.clear
        self
      end

      # Update the access token, send it to every joined channel so RLS reflects
      # the new auth context, and remember it for future joins.
      #
      # Safe to call before `connect`: the token is always written to
      # `@access_token` / `@params` so the next subscribe picks it up via
      # `Channel#inject_postgres_changes_bindings`. The ACCESS_TOKEN frame fan-out
      # only runs once the socket is actually connected.
      def set_auth(token)
        @access_token = token
        @params["access_token"] = token if @params.is_a?(Hash)

        if connected?
          @channels.each do |channel|
            next unless channel.joined?

            msg = Message.new(
              event:   Types::ChannelEvents::ACCESS_TOKEN,
              topic:   channel.topic,
              payload: { "access_token" => token },
              ref:     next_ref
            )
            @socket.send(JSON.generate(
              "event"    => msg.event,
              "topic"    => msg.topic,
              "payload"  => msg.payload,
              "ref"      => msg.ref,
              "join_ref" => nil
            ))
          end
        end
      end

      # Manually emit a heartbeat. Real adapters typically wire this onto a timer.
      def send_heartbeat
        return unless connected?

        @socket.send(JSON.generate(
          "event"    => Types::ChannelEvents::HEARTBEAT,
          "topic"    => Types::PHOENIX_TOPIC,
          "payload"  => {},
          "ref"      => next_ref,
          "join_ref" => nil
        ))
      end

      # Used by Channel — increments a shared counter so refs are unique per socket.
      def next_ref
        @ref += 1
        @ref.to_s
      end

      # Used by Channel#send_push. If the socket isn't connected yet, the frame
      # is buffered and flushed automatically when the socket opens — matches
      # supabase-py's send_buffer so offline pushes aren't silently dropped.
      def push(message)
        frame = JSON.generate(
          "event"    => message.event,
          "topic"    => message.topic,
          "payload"  => message.payload,
          "ref"      => message.ref,
          "join_ref" => message.join_ref
        )

        if connected?
          @socket.send(frame)
        else
          @send_buffer_mutex.synchronize { @send_buffer << frame }
        end
      end

      # NOTE: supabase-py exposes this as `client.send(message)`. In Ruby that
      # name would shadow Object#send and break reflective `obj.send(:method)`
      # calls, so the rb port uses `push` instead.

      private

      # Lazy-construct the production WebSocket transport. Lives behind an autoload
      # so that callers who inject their own `transport:` don't pay the cost of
      # `require "websocket-client-simple"`, and so that the dependency only loads
      # once it's actually needed (matches the per-adapter require pattern in
      # lib/supabase/realtime/sockets/*).
      def build_default_transport
        require_relative "sockets/websocket_client_simple"
        Sockets::WebsocketClientSimple.new(url: @url)
      end

      def attach_socket
        @socket.on_message { |raw| handle_inbound(raw) }
        @socket.on_open    { handle_socket_open }
        @socket.on_close   { handle_socket_close }
      end

      def handle_socket_open
        flush_send_buffer
        start_heartbeat
        rejoin_channels
      end

      def flush_send_buffer
        buffered = @send_buffer_mutex.synchronize do
          frames = @send_buffer
          @send_buffer = []
          frames
        end
        buffered.each do |frame|
          begin
            @socket.send(frame)
          rescue StandardError
            # Drop on send-error — re-queueing would risk a tight loop if the
            # socket closes immediately. The push's own timeout will surface
            # the failure to the caller.
          end
        end
      end

      def handle_socket_close
        stop_heartbeat
        return if @intentionally_closed || !@auto_reconnect

        schedule_reconnect
      end

      def start_heartbeat
        return if @heartbeat_interval.nil? || @heartbeat_interval <= 0
        return if @heartbeat_thread&.alive?

        # Mirror supabase-py: clamp to a 15s floor so an overeager caller can't
        # hammer the server with sub-15s heartbeats.
        interval = [@heartbeat_interval, 15].max
        @heartbeat_thread = Thread.new do
          Thread.current.report_on_exception = false
          loop do
            sleep interval
            break unless connected?

            begin
              send_heartbeat
            rescue StandardError
              # Swallow — a transient send error shouldn't kill the heartbeat loop.
            end
          end
        end
      end

      def stop_heartbeat
        thread = @heartbeat_thread
        @heartbeat_thread = nil
        thread.kill if thread && thread != Thread.current
      end

      def schedule_reconnect
        return if @reconnect_thread&.alive?

        initial   = @initial_backoff
        max_tries = @max_retries

        @reconnect_thread = Thread.new do
          Thread.current.report_on_exception = false
          retries = 0
          while retries < max_tries
            retries += 1
            wait = [initial * (2**(retries - 1)), 60.0].min
            sleep wait
            break if @intentionally_closed

            begin
              @socket.connect
              break # on_open will fire and restart heartbeat + rejoin channels
            rescue StandardError
              # Try again until max_retries is hit.
            end
          end
          @reconnect_thread = nil
        end
      end

      def stop_reconnect
        thread = @reconnect_thread
        @reconnect_thread = nil
        thread.kill if thread && thread != Thread.current
      end

      def rejoin_channels
        @channels.each do |channel|
          # Only rejoin channels the caller still cares about: JOINED (live
          # subscription that the socket close interrupted) or JOINING (join
          # handshake was in flight when the socket dropped). After
          # `unsubscribe` a channel is LEAVING or CLOSED — rejoining it would
          # silently revive a subscription the caller explicitly tore down.
          next unless channel.joined? || channel.joining?

          channel.rejoin
        end
      end

      def handle_inbound(raw)
        message = Message.parse(raw)
        # `parse` returns nil on malformed JSON (US-017) — skip the frame so the
        # socket adapter's read-loop keeps running for the next valid frame.
        return if message.nil? || message.topic.nil?

        @channels.each do |channel|
          channel.dispatch(message) if channel.topic == message.topic
        end
      end

      def normalize_url(url, params)
        normalized = url.to_s.dup
        normalized.sub!(%r{\Ahttp://},  "ws://")
        normalized.sub!(%r{\Ahttps://}, "wss://")
        normalized = "#{normalized}/websocket" unless normalized.end_with?("/websocket")

        query = { "vsn" => Types::VSN }.merge(params.transform_keys(&:to_s)) if params && !params.empty?
        query ||= { "vsn" => Types::VSN }

        separator = normalized.include?("?") ? "&" : "?"
        "#{normalized}#{separator}#{URI.encode_www_form(query)}"
      end
    end
  end
end
