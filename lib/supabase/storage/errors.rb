# frozen_string_literal: true

module Supabase
  module Storage
    module Errors
      # Base class for any failure raised by the storage gem.
      class StorageError < StandardError; end

      # Raised when the Storage REST API returns a non-2xx response.
      # Mirrors supabase-py's StorageApiError contract — exposes :message, :code (the
      # API's `error` field, e.g. "InvalidKey"), and :status (HTTP status).
      class StorageApiError < StorageError
        attr_reader :code, :status

        def initialize(message, code: nil, status: nil)
          @code = code
          @status = status
          super(message.to_s)
        end

        def to_h
          { "name" => "StorageApiError", "message" => message, "code" => @code, "status" => @status }
        end
      end
    end
  end
end
