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
    #   raw = functions.invoke("hello-world", body: { name: "Ada" })
    #   # => raw response body as a String (default — parity with supabase-py).
    #   data = functions.invoke("hello-world", body: { name: "Ada" }, response_type: :json)
    #   # => parsed JSON Hash / Array / scalar.
    #
    # JSON parsing is opt-in via `response_type: :json` — Content-Type is not
    # consulted (deliberately different from supabase-js).
    #
    # For the legacy `Types::Response` wrapper (data + status + headers), pass
    # `return_response: true` — note that `Types::Response` is deprecated and
    # will be removed in a future release.
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
      # @param response_type [Symbol, String] :json to parse the response body
      #   as JSON; anything else (the default) returns the raw response body as
      #   a String. Matches supabase-py's contract — parsing is opt-in by
      #   caller, never inferred from the response Content-Type.
      # @param query [Hash, nil] extra query-string params
      # @param return_response [Boolean] when true, return the deprecated
      #   {Types::Response} wrapper (data + status + headers) instead of the
      #   bare parsed body. Default `false` (US-026). The wrapper is scheduled
      #   for removal — prefer reading the data directly.
      # @return [Object, Types::Response] parsed body (Hash / String / Array /
      #   nil) by default; the deprecated `Types::Response` struct when
      #   `return_response: true` is passed.
      def invoke(function_name, body: nil, headers: {}, method: "POST", region: nil, response_type: :text,
                 query: nil, return_response: false)
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

        data = parse_body(response, response_type)
        return data unless return_response

        Types::Response.new(data: data, status: response.status, headers: response.headers)
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

        # Parity with supabase-py: JSON is parsed *only* when the caller opts
        # in via `response_type: :json`. Content-Type is never used to infer
        # parsing (that's the supabase-js behavior, deliberately not ported).
        return response.body unless response_type.to_s == "json"

        parse_json_safe(response.body) || response.body
      end

      def parse_json_safe(body)
        JSON.parse(body) if body && !body.empty?
      rescue JSON::ParserError
        nil
      end
    end
  end
end
