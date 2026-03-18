# frozen_string_literal: true

require "faraday"
require "json"

module Supabase
  module Auth
    class Api
      CONTENT_TYPE = "application/json;charset=UTF-8"

      attr_reader :url, :headers

      # @param url [String] The GoTrue API base URL
      # @param headers [Hash] Default headers to include on every request (e.g., apikey)
      # @param http_client [Faraday::Connection, nil] Optional custom Faraday client
      def initialize(url:, headers: {}, http_client: nil)
        @url = url
        @headers = headers
        @http_client = http_client
      end

      # @param path [String] Request path (relative to base URL)
      # @param headers [Hash] Additional headers for this request
      # @param params [Hash] Query parameters
      # @return [Hash] Parsed JSON response
      def get(path, headers: {}, params: {})
        request(:get, path, headers: headers, params: params)
      end

      # @param path [String] Request path (relative to base URL)
      # @param body [Hash] Request body (will be serialized to JSON)
      # @param headers [Hash] Additional headers for this request
      # @param params [Hash] Query parameters
      # @return [Hash] Parsed JSON response
      def post(path, body: {}, headers: {}, params: {})
        request(:post, path, body: body, headers: headers, params: params)
      end

      # @param path [String] Request path (relative to base URL)
      # @param body [Hash] Request body (will be serialized to JSON)
      # @param headers [Hash] Additional headers for this request
      # @param params [Hash] Query parameters
      # @return [Hash] Parsed JSON response
      def put(path, body: {}, headers: {}, params: {})
        request(:put, path, body: body, headers: headers, params: params)
      end

      # @param path [String] Request path (relative to base URL)
      # @param headers [Hash] Additional headers for this request
      # @param params [Hash] Query parameters
      # @return [Hash] Parsed JSON response
      def delete(path, headers: {}, params: {})
        request(:delete, path, headers: headers, params: params)
      end

      private

      def connection
        @connection ||= @http_client || build_connection
      end

      def build_connection
        Faraday.new(url: @url) do |f|
          f.request :json
          f.response :raise_error
          f.adapter Faraday.default_adapter
        end
      end

      def request(method, path, body: nil, headers: {}, params: {})
        merged_headers = @headers.merge("Content-Type" => CONTENT_TYPE).merge(headers)
        full_path = build_path(path)

        response = connection.run_request(method, full_path, body ? JSON.generate(body) : nil, merged_headers) do |req|
          req.params.update(params) unless params.empty?
        end

        parse_response(response)
      rescue Faraday::ClientError, Faraday::ServerError => e
        handle_error(e)
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

      def handle_error(error)
        response = error.response
        status = response[:status]
        body = parse_error_body(response[:body])

        message = body["error_description"] || body["msg"] || body["message"] || error.message
        code = body["error_code"] || body["error"] || body["code"]

        raise Errors::AuthApiError.new(message, status: status, code: code)
      end

      def parse_error_body(body)
        return {} if body.nil? || body.empty?

        JSON.parse(body)
      rescue JSON::ParserError
        {}
      end
    end
  end
end
