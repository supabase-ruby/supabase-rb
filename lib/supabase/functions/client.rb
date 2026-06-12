# frozen_string_literal: true

require "faraday"
require "faraday/follow_redirects"
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
    #   # => Ruby returns String; encoding depends on response_type
    #   #    (:text → UTF-8, :binary → ASCII-8BIT, :json → parsed object).
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
      # Always POSTs. The `method:` and `query:` kwargs were dropped in US-030
      # — they had no analogue in supabase-py and only existed to mirror the
      # supabase-js surface (see Open Question §9.4). Region routing still
      # appends `forceFunctionRegion` to the URL via the region branch below.
      #
      # @param function_name [String]
      # @param body [Hash, String, nil] JSON-encoded if Hash, sent as-is if String
      # @param headers [Hash] per-invocation headers (merged over the client defaults)
      # @param region [String, nil] one of {Types::FunctionRegion}::ALL
      # @param response_type [Symbol, String] controls how the response body
      #   is returned. Ruby always returns a `String` (unlike supabase-py, which
      #   returns `bytes` for binary). Supported values:
      #     * `:json`   — parse the body as JSON; returns Hash / Array / scalar.
      #     * `:text`   — return a `String` with `Encoding::UTF_8` (default).
      #     * `:binary` — return a `String` with `Encoding::BINARY`
      #       (`ASCII-8BIT`), byte-for-byte equal to the HTTP response body.
      #   Parsing/encoding is opt-in by the caller, never inferred from the
      #   response Content-Type.
      # @param return_response [Boolean] when true, return the deprecated
      #   {Types::Response} wrapper (data + status + headers) instead of the
      #   bare parsed body. Default `false` (US-026). The wrapper is scheduled
      #   for removal — prefer reading the data directly.
      # @return [Object, Types::Response] parsed body (Hash / String / Array /
      #   nil) by default; the deprecated `Types::Response` struct when
      #   `return_response: true` is passed.
      def invoke(function_name, body: nil, headers: {}, region: nil, response_type: :text,
                 return_response: false)
        validate_function_name!(function_name)
        validate_region!(region)

        merged_headers = @headers.merge(headers)
        merged_query   = {}

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
          :post,
          "#{@base_url}/#{function_name}",
          encoded_body,
          merged_headers
        ) do |req|
          req.params.update(merged_query) unless merged_query.empty?
        end

        raise_for_status!(response)
        raise_for_relay!(response)

        data = parse_body(response, response_type)
        return data unless return_response

        Types::Response.new(data: data, status: response.status, headers: response.headers)
      end

      private

      def build_session
        Faraday.new(url: @base_url, ssl: { verify: @verify }, proxy: @proxy) do |f|
          f.response :follow_redirects
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

      # Reject regions that aren't in {Types::FunctionRegion::ALL}. Nil is fine
      # (means "let the server pick"); FunctionRegion::ANY is explicitly allowed
      # — the AC's `|| region == FunctionRegion::ANY` clause is redundant with
      # the `ALL` check (ANY is already in ALL) but kept here in spirit so
      # callers passing the sentinel string `"any"` also pass.
      def validate_region!(region)
        return if region.nil?
        return if Types::FunctionRegion::ALL.include?(region)

        raise ArgumentError,
              "region must be one of Supabase::Functions::Types::FunctionRegion::ALL " \
              "(got #{region.inspect})"
      end

      def raise_for_relay!(response)
        # The relay layer signals its own errors via this response header (set to
        # "true"). The function itself doesn't set this — only the relay.
        #
        # DIVERGES FROM PY (intentional): supabase-py reads `x-relay-header`,
        # which is a long-standing bug — the actual relay error header is
        # `x-relay-error` (see @supabase/functions-js: `headers.get('x-relay-error')`).
        # We follow supabase-js (the canonical client) so relay errors are
        # detected against a real Supabase deployment.
        relay = response.headers["x-relay-error"] || response.headers["X-Relay-Error"]
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
        body = response.body
        return body if body.nil?

        case response_type.to_s
        when "json"
          return body if body.empty?

          # The caller explicitly asked for JSON, so a body that doesn't parse
          # is a contract violation and must surface — not be silently handed
          # back as a raw String (which the old `parse_json_safe(body) || body`
          # did, leaving callers to discover the wrong type at runtime). Mirrors
          # supabase-py's `response.json()`, which raises on invalid JSON.
          JSON.parse(body)
        when "binary"
          # Byte-for-byte copy with BINARY (ASCII-8BIT) encoding. Faraday may
          # hand us the body tagged as UTF-8 even when it's raw bytes; force
          # the encoding so callers get a stable, lossless String.
          body.dup.force_encoding(Encoding::BINARY)
        else
          # :text (default) — return a UTF-8 String.
          body.dup.force_encoding(Encoding::UTF_8)
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
