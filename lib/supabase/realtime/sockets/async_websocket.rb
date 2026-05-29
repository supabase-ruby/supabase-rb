# frozen_string_literal: true

require "async"
require "async/http/endpoint"
require "async/websocket/client"
require "protocol/websocket/message"

require_relative "../errors"
require_relative "../socket"

module Supabase
  module Realtime
    module Sockets
      # {Socket} implementation backed by the async-websocket gem (socketry/async).
      #
      # Unlike {WebsocketClientSimple} — which spawns a background OS thread for
      # the read loop — this adapter runs entirely inside the calling fiber's
      # Async reactor. Pick it when:
      #
      #   - your app already runs on the socketry/async stack (Falcon, or
      #     supabase-rb's own async REST clients via async-http-faraday), so
      #     a single reactor owns all I/O;
      #   - you want cooperative concurrency without cross-thread callback
      #     hops or mutexes on listener state.
      #
      #   require "async"
      #   require "supabase/realtime"
      #   require "supabase/realtime/sockets/async_websocket"
      #
      #   Async do
      #     socket  = Supabase::Realtime::Sockets::AsyncWebsocket.new(url: ws_url)
      #     client  = Supabase::Realtime::Client.new(url: ws_url, socket: socket)
      #     client.connect
      #
      #     channel = client.channel("realtime:public:users")
      #     channel.on_postgres_changes("INSERT", schema: "public", table: "users") { |p| puts p }
      #     channel.subscribe
      #   end
      #
      # All callbacks (on_open / on_message / on_close / on_error, and every
      # downstream channel listener) run inside the Async reactor on the same
      # fiber tree as the caller — no thread hops, no mutexes required for
      # state owned by the reactor.
      class AsyncWebsocket
        include Socket

        # @param url       [String]   ws(s):// URL including query params
        # @param headers   [Hash]     extra HTTP headers sent on the upgrade request
        # @param parent    [Async::Task, nil] reactor task to attach the session
        #   to. Defaults to {Async::Task.current?} resolved at connect-time, so
        #   callers must be inside an `Async { ... }` block.
        # @param connector [#connect] dependency-injection seam — defaults to
        #   {Async::WebSocket::Client}. Tests pass a fake that returns a stub
        #   connection so no real socket is opened.
        def initialize(url:, headers: {}, parent: nil, connector: ::Async::WebSocket::Client)
          @url        = url
          @headers    = headers
          @parent     = parent
          @connector  = connector
          @connection = nil
          @session    = nil
        end

        def connect
          return if connected?

          parent = @parent || ::Async::Task.current?
          unless parent
            raise Errors::RealtimeError,
                  "Supabase::Realtime::Sockets::AsyncWebsocket#connect must run inside an Async { ... } block " \
                  "(or be constructed with parent:)"
          end

          endpoint = ::Async::HTTP::Endpoint.parse(@url)
          ready    = ::Async::Promise.new

          @session = parent.async do
            @connector.connect(endpoint, headers: header_pairs) do |connection|
              @connection = connection
              fire_open
              ready.resolve(true)

              read_loop(connection)
            end
          rescue => err
            fire_error(err)
            ready.reject(err) unless ready.resolved?
          ensure
            fire_close
          end

          # Cooperative wait — Promise buffers the resolution, so this returns
          # immediately whether the session task got there first or not. After
          # this, callers can rely on connected?.
          ready.wait
          nil
        end

        def close
          conn    = @connection
          session = @session
          @connection = nil
          @session    = nil

          # Closing the connection makes #read return nil → read_loop exits →
          # the session task terminates naturally. This is more reliable than
          # task.stop, which doesn't always interrupt a fiber blocked on a
          # non-IO suspend point (queues, notifications).
          begin
            conn&.close
          rescue StandardError
            # Connection may already be torn down — ignore.
          end

          # Belt-and-braces: if the connection didn't unblock the read, stop
          # the task as a fallback. No-op if it already finished.
          session&.stop
        end

        def send(payload)
          conn = @connection
          return unless conn

          # Connection#write auto-wraps UTF-8 strings in a text frame, which is
          # what the Phoenix protocol expects.
          conn.write(payload)
          conn.flush
        end

        def connected?
          !@connection.nil?
        end

        # ----- Internal callback fan-outs (public so the read task can reach them) -----

        def fire_open
          open_callbacks.each(&:call)
        end

        def fire_message(payload)
          message_callbacks.each { |cb| cb.call(payload) }
        end

        def fire_close
          return if @connection.nil? && close_callbacks.empty?

          @connection = nil
          close_callbacks.each(&:call)
        end

        def fire_error(err)
          error_callbacks.each { |cb| cb.call(err) }
        end

        private

        def header_pairs
          @headers.map { |k, v| [k.to_s, v.to_s] }
        end

        def read_loop(connection)
          while (message = connection.read)
            next unless message.is_a?(::Protocol::WebSocket::TextMessage)

            fire_message(message.buffer.to_s)
          end
        rescue ::Async::Stop
          # graceful shutdown — initiated by #close
        rescue => err
          fire_error(err)
        end
      end
    end
  end
end
