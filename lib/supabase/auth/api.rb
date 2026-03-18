# frozen_string_literal: true

require "faraday"
require "json"

module Supabase
  module Auth
    class Api
      CONTENT_TYPE = "application/json;charset=UTF-8"
      UUID_REGEX = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

      attr_reader :url, :headers

      # @param url [String] The GoTrue API base URL
      # @param headers [Hash] Default headers to include on every request (e.g., apikey)
      # @param http_client [Faraday::Connection, nil] Optional custom Faraday client
      def initialize(url:, headers: {}, http_client: nil)
        @url = url
        @headers = headers
        @http_client = http_client
      end

      # Central HTTP dispatch method. Builds URL, merges headers (including API version
      # and Authorization), handles redirect_to as query param, parses JSON, applies
      # optional transform, and maps errors via Helpers.handle_exception.
      #
      # @param method [String, Symbol] HTTP method (GET, POST, PUT, DELETE)
      # @param path [String] Request path (relative to base URL)
      # @param jwt [String, nil] Bearer token for Authorization header
      # @param body [Hash, nil] Request body (serialized to JSON)
      # @param params [Hash] Query parameters
      # @param headers [Hash] Additional headers for this request
      # @param redirect_to [String, nil] If present, added as redirect_to query param
      # @param xform [Proc, nil] Optional transform function applied to parsed response
      # @param no_resolve_json [Boolean] If true, return raw Faraday::Response
      # @return [Hash, Object] Parsed JSON response, transformed result, or raw response
      def _request(method, path, jwt: nil, body: nil, params: {}, headers: {}, redirect_to: nil, xform: nil, no_resolve_json: false)
        merged_headers = @headers.merge(headers)
        merged_headers["Content-Type"] ||= CONTENT_TYPE
        merged_headers[Constants::API_VERSION_HEADER_NAME] ||= Constants::API_VERSIONS.keys.last
        merged_headers["Authorization"] = "Bearer #{jwt}" if jwt

        query = params.dup
        query["redirect_to"] = redirect_to if redirect_to

        full_path = build_path(path)
        json_body = body ? JSON.generate(body) : nil

        response = connection.run_request(method.to_s.downcase.to_sym, full_path, json_body, merged_headers) do |req|
          req.params.update(query) unless query.empty?
        end

        result = no_resolve_json ? response : parse_response(response)

        xform ? xform.call(result) : result
      rescue Faraday::Error => e
        raise Helpers.handle_exception(e)
      rescue StandardError => e
        raise Helpers.handle_exception(e)
      end

      # @param id [String] UUID to validate
      # @raise [ArgumentError] if not a valid UUID format
      def _validate_uuid(id)
        unless id.is_a?(String) && id.match?(UUID_REGEX)
          raise ArgumentError, "Invalid id, '#{id}' is not a valid uuid"
        end
      end

      # Convenience methods that delegate to _request

      def get(path, headers: {}, params: {})
        _request(:get, path, headers: headers, params: params)
      end

      def post(path, body: {}, headers: {}, params: {})
        _request(:post, path, body: body, headers: headers, params: params)
      end

      def put(path, body: {}, headers: {}, params: {})
        _request(:put, path, body: body, headers: headers, params: params)
      end

      def delete(path, headers: {}, params: {})
        _request(:delete, path, headers: headers, params: params)
      end

      private

      def connection
        @connection ||= @http_client || build_connection
      end

      def build_connection
        Faraday.new(url: @url) do |f|
          f.response :raise_error
          f.adapter Faraday.default_adapter
        end
      end

      def build_path(path)
        base_path = URI.parse(@url).path.chomp("/")
        "#{base_path}/#{path.sub(%r{^/}, '')}"
      end

      def parse_response(response)
        return {} if response.body.nil? || response.body.empty?

        JSON.parse(response.body)
      rescue JSON::ParserError
        {}
      end
    end
  end
end
