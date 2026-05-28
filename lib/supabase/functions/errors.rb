# frozen_string_literal: true

module Supabase
  module Functions
    module Errors
      # Base class — rescue this to catch any Functions-API failure.
      class FunctionsError < StandardError
        attr_reader :name, :status

        def initialize(message, name:, status:)
          @name = name
          @status = status
          super(message.to_s)
        end

        def to_h
          { "name" => @name, "message" => message, "status" => @status }
        end
      end

      # Raised when the edge function returns a non-2xx HTTP response.
      class FunctionsHttpError < FunctionsError
        def initialize(message, status: nil)
          super(message, name: "FunctionsHttpError", status: status || 400)
        end
      end

      # Raised when the Supabase relay (the layer in front of the function) reports
      # an error — distinguishable from a function-side error via the x-relay-header
      # response header.
      class FunctionsRelayError < FunctionsError
        def initialize(message, status: nil)
          super(message, name: "FunctionsRelayError", status: status || 400)
        end
      end
    end
  end
end
