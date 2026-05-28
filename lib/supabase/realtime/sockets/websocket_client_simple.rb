# frozen_string_literal: true

require "websocket-client-simple"

require_relative "../socket"

module Supabase
  module Realtime
    module Sockets
      # {Socket} implementation backed by the websocket-client-simple gem.
      #
      # The underlying gem spawns a background thread to read frames from the
      # server, so every callback this adapter fires (on_open / on_message /
      # on_close / on_error — and downstream, every user listener registered
      # on a Channel) runs on **that background thread**. Callers are
      # responsible for thread-safety in their listeners.
      #
      #   require "supabase/realtime"
      #   require "supabase/realtime/sockets/websocket_client_simple"
      #
      #   socket = Supabase::Realtime::Sockets::WebsocketClientSimple.new(url: ws_url)
      #   client = Supabase::Realtime::Client.new(url: ws_url, socket: socket)
      #   client.connect
      class WebsocketClientSimple
        include Socket

        # @param url     [String] full ws(s):// URL including query params
        # @param headers [Hash]   extra HTTP headers sent on the upgrade request
        # @param connector [#connect] dependency injection seam — defaults to
        #   ::WebSocket::Client::Simple. Tests pass a fake that returns a stub
        #   WS client so we never open a real socket.
        def initialize(url:, headers: {}, connector: ::WebSocket::Client::Simple)
          @url       = url
          @headers   = headers
          @connector = connector
          @ws        = nil
        end

        def connect
          return if connected?

          self_ref = self
          @ws = @connector.connect(@url, headers: @headers) do |client|
            client.on(:open)    { self_ref.fire_open }
            client.on(:message) { |msg| self_ref.fire_message(msg) }
            client.on(:close)   { |reason| self_ref.fire_close(reason) }
            client.on(:error)   { |err| self_ref.fire_error(err) }
          end
          nil
        end

        def close
          @ws&.close
          @ws = nil
        end

        def send(payload)
          @ws&.send(payload)
        end

        def connected?
          !@ws.nil? && @ws.open?
        end

        # ----- Internal callback shims (called by the WS background thread) -----
        # Public so the connect block can reach them, not part of the Socket
        # contract callers should use.

        def fire_open
          open_callbacks.each(&:call)
        end

        # websocket-client-simple yields a Frame::Incoming object whose #data
        # holds the payload and whose #type is :text / :binary / :ping / etc.
        # We only forward text frames — Phoenix doesn't use binary.
        def fire_message(msg)
          return unless msg.respond_to?(:type) ? msg.type == :text : true

          payload = msg.respond_to?(:data) ? msg.data : msg.to_s
          message_callbacks.each { |cb| cb.call(payload) }
        end

        def fire_close(_reason = nil)
          @ws = nil
          close_callbacks.each(&:call)
        end

        def fire_error(err)
          error_callbacks.each { |cb| cb.call(err) }
        end
      end
    end
  end
end
