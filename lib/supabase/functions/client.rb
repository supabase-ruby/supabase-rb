# frozen_string_literal: true

require "faraday"
require "json"
require "uri"

require_relative "errors"
require_relative "types"
require_relative "version"

module Supabase
  module Functions
    # Sync Edge Functions client. Constructed once per project; reused across invocations.
    #
    #   functions = Supabase::Functions::Client.new(
    #     base_url: "https://project.supabase.co/functions/v1",
    #     headers:  { "Authorization" => "Bearer #{key}" }
    #   )
    #
    #   response = functions.invoke("hello-world", body: { name: "Ada" })
    #   response.data    # => parsed JSON or raw bytes
    #   response.status  # => 200
    #   response.headers # => { "content-type" => "application/json", ... }
    class Client
      VALID_METHODS = %w[GET OPTIONS HEAD POST PUT PATCH DELETE].freeze

      attr_reader :base_url, :headers

      # @param base_url [String] full URL to the Edge Functions endpoint
      # @param headers  [Hash] static headers attached to every invocation
      # @param http_client [Faraday::Connection, nil] inject a pre-built Faraday for tests
      # @param verify [Boolean] TLS cert verification
      # @param proxy [String, nil]
      # @param timeout [Numeric, nil] per-request timeout (seconds), default 60
      def initialize(base_url:, headers: {}, http_client: nil, verify: true, proxy: nil, timeout: nil)
        raise ArgumentError, "base_url must be an http(s) URL" unless http_url?(base_url)

        @base_url = base_url.chomp("/")
        @verify   = verify
        @proxy    = proxy
        @timeout  = timeout || 60

        @headers = {
          "X-Client-Info" => "supabase-rb/functions-rb v#{VERSION}"
        }.merge(headers)

        @session = http_client || build_session
      end

      # Replace the Authorization header (e.g. when a user signs in / out).
      def set_auth(token)
        @headers["Authorization"] = "Bearer #{token}"
      end

      # Invoke an Edge Function by name.
      #
      # @param function_name [String]
      # @param body [Hash, String, nil] JSON-encoded if Hash, sent as-is if String
      # @param headers [Hash] per-invocation headers (merged over the client defaults)
      # @param method [String, Symbol] HTTP method, defaults to "POST"
      # @param region [String, nil] one of {Types::FunctionRegion}::ALL
      # @param response_type [Symbol, String] :json to parse JSON, anything else returns raw bytes
      # @param query [Hash, nil] extra query-string params
      # @return [Types::Response]
      def invoke(function_name, body: nil, headers: {}, method: "POST", region: nil, response_type: :text, query: nil)
        validate_function_name!(function_name)

        http_method = method.to_s.upcase
        unless VALID_METHODS.include?(http_method)
          raise ArgumentError, "method must be one of #{VALID_METHODS.join(', ')}"
        end

        merged_headers = @headers.merge(headers)
        merged_query   = (query || {}).transform_keys(&:to_s)

        if region && region != Types::FunctionRegion::ANY
          merged_headers["x-region"] = region
          merged_query["forceFunctionRegion"] = region
        end

        encoded_body =
          case body
          when nil
            nil
          when String
            merged_headers["Content-Type"] ||= "text/plain"
            body
          when Hash, Array
            merged_headers["Content-Type"] ||= "application/json"
            JSON.generate(body)
          else
            raise ArgumentError, "body must be a String, Hash, Array, or nil (got #{body.class})"
          end

        response = @session.run_request(
          http_method.downcase.to_sym,
          "#{@base_url}/#{function_name}",
          encoded_body,
          merged_headers
        ) do |req|
          req.params.update(merged_query) unless merged_query.empty?
        end

        raise_for_relay!(response)
        raise_for_status!(response)

        Types::Response.new(
          data:    parse_body(response, response_type),
          status:  response.status,
          headers: response.headers
        )
      end

      private

      def build_session
        Faraday.new(url: @base_url, ssl: { verify: @verify }, proxy: @proxy) do |f|
          f.options.timeout = @timeout
          f.options.open_timeout = @timeout
          f.adapter Faraday.default_adapter
        end
      end

      def http_url?(url)
        scheme = URI.parse(url.to_s).scheme
        %w[http https].include?(scheme)
      rescue URI::InvalidURIError
        false
      end

      def validate_function_name!(name)
        return if name.is_a?(String) && !name.strip.empty?

        raise ArgumentError, "function_name must be a non-empty String"
      end

      def raise_for_relay!(response)
        # The relay layer signals its own errors via this response header (set to
        # "true"). The function itself doesn't set this — only the relay.
        relay = response.headers["x-relay-header"] || response.headers["X-Relay-Header"]
        return unless relay == "true"

        parsed = parse_json_safe(response.body) || {}
        raise Errors::FunctionsRelayError.new(parsed["error"] || "Relay error", status: response.status)
      end

      def raise_for_status!(response)
        return if (200..299).include?(response.status)

        parsed = parse_json_safe(response.body) || {}
        message = parsed["error"] || "An error occurred while requesting the edge function"
        raise Errors::FunctionsHttpError.new(message, status: response.status)
      end

      def parse_body(response, response_type)
        return response.body if response.body.nil? || response.body.empty?

        if response_type.to_s == "json"
          parse_json_safe(response.body) || response.body
        else
          # Auto-detect JSON: if the server says application/json, parse it.
          content_type = response.headers["content-type"] || response.headers["Content-Type"] || ""
          content_type.include?("application/json") ? (parse_json_safe(response.body) || response.body) : response.body
        end
      end

      def parse_json_safe(body)
        JSON.parse(body) if body && !body.empty?
      rescue JSON::ParserError
        nil
      end
    end
  end
end
