# frozen_string_literal: true

require "json"
require "faraday"

require_relative "errors"

module Supabase
  module Storage
    # Mixin used by BucketApi and FileApi. Holds the shared HTTP wiring: build a Faraday
    # request, raise StorageApiError on non-2xx, and parse JSON bodies.
    #
    # Including classes must expose @session (Faraday::Connection), @base_url (String
    # ending in "/"), and @headers (Hash).
    module Request
      private

      def _request(method, segments, json: nil, headers: nil, query: nil, body: nil, raw_response: false)
        url = Utils.join_url(@base_url, segments, query)
        merged_headers = @headers.merge(headers || {})

        response = @session.run_request(method.to_s.downcase.to_sym, url, nil, merged_headers) do |req|
          if json
            req.headers["Content-Type"] ||= "application/json"
            req.body = JSON.generate(json)
          elsif body
            req.body = body
          end
        end

        raise_for_status(response)
        return response if raw_response

        parse_json(response.body)
      end

      def raise_for_status(response)
        return if (200..299).include?(response.status)

        parsed = parse_json_safe(response.body) || {}
        raise Errors::StorageApiError.new(
          parsed["message"] || "HTTP #{response.status}",
          code:   parsed["error"]      || "InternalError",
          status: parsed["statusCode"] || response.status
        )
      end

      def parse_json(body)
        return nil if body.nil? || body.empty?

        JSON.parse(body)
      rescue JSON::ParserError
        body
      end

      def parse_json_safe(body)
        JSON.parse(body) if body && !body.empty?
      rescue JSON::ParserError
        nil
      end
    end
  end
end
