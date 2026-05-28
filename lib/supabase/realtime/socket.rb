# frozen_string_literal: true

module Supabase
  module Realtime
    # Transport interface that {Client} talks to. A real implementation wraps a
    # WebSocket; {TestSocket} stays in-memory for specs.
    #
    # Implementations must provide:
    #
    #   - `connect`           — open the underlying transport
    #   - `close`             — tear it down
    #   - `send(payload)`     — push one raw JSON frame to the server
    #   - `connected?`        — boolean state predicate
    #   - `on_message(&blk)`  — register an inbound-frame callback (raw JSON string)
    #   - `on_open(&blk)`     — register an on-open callback
    #   - `on_close(&blk)`    — register an on-close callback
    #
    # The Client never assumes a specific WebSocket library; bring your own
    # (websocket-client-simple for sync, async-websocket for async, etc.) by
    # implementing this interface.
    module Socket
      # The minimum surface. Including it gives default no-op implementations so
      # subclasses can override piecemeal.
      def connect; raise NotImplementedError; end
      def close;   raise NotImplementedError; end
      def send(_payload); raise NotImplementedError; end
      def connected?; raise NotImplementedError; end

      def on_message(&blk); message_callbacks << blk; end
      def on_open(&blk);    open_callbacks    << blk; end
      def on_close(&blk);   close_callbacks   << blk; end
      def on_error(&blk);   error_callbacks   << blk; end

      def message_callbacks; @message_callbacks ||= []; end
      def open_callbacks;    @open_callbacks    ||= []; end
      def close_callbacks;   @close_callbacks   ||= []; end
      def error_callbacks;   @error_callbacks   ||= []; end
    end
  end
end
