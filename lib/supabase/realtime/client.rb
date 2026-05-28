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
      attr_reader :url, :params, :access_token, :channels, :socket, :timeout

      # @param url    [String] WebSocket endpoint (ws:// or wss://). Plain http(s) are upgraded.
      # @param params [Hash]   query-string params merged onto the URL (e.g. apikey/access_token)
      # @param socket [Socket, nil] inject your own transport (defaults to nil — caller wires it up)
      # @param timeout [Numeric] default per-push timeout (seconds)
      def initialize(url:, params: {}, socket: nil, timeout: Types::DEFAULT_TIMEOUT_SECONDS)
        @url     = normalize_url(url, params)
        @params  = params
        @access_token = params[:access_token] || params["access_token"]
        @channels = {}
        @socket   = socket
        @timeout  = timeout
        @ref      = 0

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

        @socket.connect
        self
      end

      def disconnect
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
        @socket.on_message do |raw|
          handle_inbound(raw)
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
