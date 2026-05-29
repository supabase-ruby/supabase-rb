# frozen_string_literal: true

module Supabase
  module Realtime
    # Mirrors realtime-py's `realtime.transformers`. Today this is a single
    # helper used to derive the HTTP endpoint from the WebSocket URL so callers
    # can hit the realtime REST surface (e.g. /api/broadcast, /connections).
    module Transformers
      module_function

      # Converts a realtime socket URL into its HTTP equivalent.
      #
      #   http_endpoint_url("wss://x.supabase.co/realtime/v1/websocket")
      #   # => "https://x.supabase.co/realtime/v1"
      #
      # Replaces the leading `ws`/`wss` scheme with `http`/`https`, strips any
      # `/socket/websocket`, `/socket`, or `/websocket` suffix, and trims
      # trailing slashes. Mirrors py's regex chain verbatim.
      def http_endpoint_url(socket_url)
        url = socket_url.to_s.sub(/\Aws/i, "http")
        url = url.sub(%r{(/socket/websocket|/socket|/websocket)/?\z}i, "")
        url.sub(%r{/+\z}, "")
      end
    end
  end
end
