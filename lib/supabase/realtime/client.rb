# frozen_string_literal: true

require "json"
require "uri"

require_relative "channel"
require_relative "message"
require_relative "types"
require_relative "version"

module Supabase
  module Realtime
    # Top-level Realtime client. Owns one {Socket}, multiplexes Channels onto it,
    # and dispatches inbound frames to whichever channel owns the topic.
    #
    # Bring your own {Socket} (e.g. websocket-client-simple adapter or async-websocket
    # adapter). For unit tests, pass a {TestSocket}.
    #
    #   socket   = Supabase::Realtime::TestSocket.new
    #   client   = Supabase::Realtime::Client.new(
    #     url: "wss://project.supabase.co/realtime/v1",
    #     params: { apikey: key },
    #     socket: socket
    #   )
    #   client.connect
    #
    #   channel = client.channel("realtime:public:users")
    #   channel.on_postgres_changes("*", schema: "public", table: "users") { |p| puts p }
    #   channel.subscribe
    class Client
      attr_reader :url, :params, :access_token, :channels, :socket, :timeout,
                  :heartbeat_interval, :auto_reconnect, :max_retries, :initial_backoff

      # @param url    [String] WebSocket endpoint (ws:// or wss://). Plain http(s) are upgraded.
      # @param params [Hash]   query-string params merged onto the URL (e.g. apikey/access_token)
      # @param socket [Socket, nil] inject your own transport (defaults to nil — caller wires it up)
      # @param timeout [Numeric] default per-push timeout (seconds)
      # @param heartbeat_interval [Numeric] seconds between automatic heartbeat pushes (0 disables)
      # @param auto_reconnect [Boolean] reconnect on unexpected socket close
      # @param max_retries [Integer] maximum reconnect attempts before giving up
      # @param initial_backoff [Numeric] seconds of delay before the first reconnect attempt;
      #   doubles each attempt up to a 60s cap (matches supabase-py)
      def initialize(url:, params: {}, socket: nil, timeout: Types::DEFAULT_TIMEOUT_SECONDS,
                     heartbeat_interval: Types::DEFAULT_HEARTBEAT_INTERVAL_SECONDS,
                     auto_reconnect: true, max_retries: 5, initial_backoff: 1.0)
        @url     = normalize_url(url, params)
        @params  = params
        @access_token = params[:access_token] || params["access_token"]
        @channels = {}
        @socket   = socket
        @timeout  = timeout
        @ref      = 0

        @heartbeat_interval = heartbeat_interval
        @auto_reconnect     = auto_reconnect
        @max_retries        = max_retries
        @initial_backoff    = initial_backoff
        @heartbeat_thread   = nil
        @reconnect_thread   = nil
        @intentionally_closed = false

        attach_socket if @socket
      end

      # Plug in a transport after construction (e.g. a websocket-client-simple wrapper).
      def use_socket(socket)
        @socket = socket
        attach_socket
        self
      end

      def connect
        raise Errors::RealtimeError, "no socket attached — call #use_socket(socket) first" unless @socket

        @intentionally_closed = false
        @socket.connect
        self
      end

      def disconnect
        @intentionally_closed = true
        stop_reconnect
        stop_heartbeat
        @socket&.close
        @channels.each_value { |ch| ch.instance_variable_set(:@state, Types::ChannelStates::CLOSED) }
        self
      end

      def connected?
        @socket && @socket.connected?
      end

      # Get or create a Channel for the given topic. Subsequent calls with the
      # same topic return the same Channel instance, matching phoenix.js semantics.
      def channel(topic, params: nil)
        @channels[topic] ||= Channel.new(topic, params: params, socket: self)
      end

      def get_channels
        @channels.values
      end

      def remove_channel(channel)
        channel.unsubscribe
        @channels.delete(channel.topic)
      end

      def remove_all_channels
        @channels.values.each { |ch| ch.unsubscribe }
        @channels.clear
      end

      # Update the access token, send it to every joined channel so RLS reflects
      # the new auth context, and remember it for future joins.
      def set_auth(token)
        @access_token = token
        @params["access_token"] = token if @params.is_a?(Hash)
        return unless @socket && @socket.connected?

        @channels.each_value do |channel|
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

      # Used by Channel#send_push.
      def push(message)
        return unless @socket

        @socket.send(JSON.generate(
          "event"    => message.event,
          "topic"    => message.topic,
          "payload"  => message.payload,
          "ref"      => message.ref,
          "join_ref" => message.join_ref
        ))
      end

      private

      def attach_socket
        @socket.on_message { |raw| handle_inbound(raw) }
        @socket.on_open    { handle_socket_open }
        @socket.on_close   { handle_socket_close }
      end

      def handle_socket_open
        start_heartbeat
        rejoin_channels
      end

      def handle_socket_close
        stop_heartbeat
        return if @intentionally_closed || !@auto_reconnect

        schedule_reconnect
      end

      def start_heartbeat
        return if @heartbeat_interval.nil? || @heartbeat_interval <= 0
        return if @heartbeat_thread&.alive?

        interval = @heartbeat_interval
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
        @channels.each_value do |channel|
          next unless channel.instance_variable_get(:@joined_once)
          next if channel.joining?

          channel.rejoin
        end
      end

      def handle_inbound(raw)
        message = Message.parse(raw)
        return if message.topic.nil?

        @channels.each_value do |channel|
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
