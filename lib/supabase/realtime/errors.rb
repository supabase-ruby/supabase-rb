# frozen_string_literal: true

module Supabase
  module Realtime
    module Errors
      class RealtimeError < StandardError; end

      # Raised when subscribe() is called more than once on the same Channel
      # instance — the Phoenix protocol only allows one join per channel.
      class AlreadyJoinedError < RealtimeError; end

      # Raised when a push waits longer than its timeout for a reply.
      class PushTimeoutError < RealtimeError; end

      # Raised when a non-JSON or malformed frame arrives on the WebSocket.
      class ProtocolError < RealtimeError; end
    end
  end
end
