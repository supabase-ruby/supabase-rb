# frozen_string_literal: true

module Supabase
  module Postgrest
    module Errors
      # Raised when the PostgREST server returns a non-success status.
      # Mirrors supabase-py's APIError — exposes :message, :code, :hint, :details
      # plus the raw error hash via {#raw}.
      class APIError < StandardError
        attr_reader :raw, :code, :hint, :details

        # @param error [Hash] parsed JSON body from a PostgREST error response
        def initialize(error = {})
          if error.is_a?(Hash)
            @raw = error
            @message = @raw["message"] || @raw[:message]
            @code = @raw["code"] || @raw[:code]
            @hint = @raw["hint"] || @raw[:hint]
            @details = @raw["details"] || @raw[:details]
          elsif error.nil?
            @raw = {}
          else
            @raw = error
            @message = "PostgREST returned non-hash error: #{error.inspect}"
          end
          super(to_s)
        end

        # Override StandardError#message so the field-level value is non-nil.
        def message
          @message.to_s
        end

        def to_s
          parts = []
          parts << "Error #{@code}:" if @code
          parts << "\nMessage: #{@message}" if @message
          parts << "\nHint: #{@hint}" if @hint
          parts << "\nDetails: #{@details}" if @details
          result = parts.join
          result.empty? ? "Empty error" : result
        end

        # @return [Hash] the raw error payload as received
        def json
          @raw
        end
      end

      # Builds a fallback error payload when the server body isn't valid JSON.
      def self.generate_default_error_message(response)
        {
          "message" => "JSON could not be generated",
          "code" => response.status.to_s,
          "hint" => "Refer to full message for details",
          "details" => response.body.to_s
        }
      end
    end
  end
end
