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

      # Raised when an operation requires an active WebSocket connection but
      # the client hasn't connected (or has been closed). Mirrors py
      # NotConnectedError so call sites can rescue the same class name.
      class NotConnectedError < RealtimeError; end

      # Raised when the server rejects a join push for authentication reasons
      # (typical case: missing/invalid apikey or access_token). Mirrors py
      # AuthorizationError.
      class AuthorizationError < RealtimeError; end
    end
  end
end
