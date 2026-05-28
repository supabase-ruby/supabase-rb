# frozen_string_literal: true

require "faraday"

require_relative "request_builder"
require_relative "version"

module Supabase
  module Postgrest
    DEFAULT_HEADERS = {
      "Accept" => "application/json",
      "Content-Type" => "application/json"
    }.freeze

    # Sync PostgREST client. Constructed once per project; reused across requests.
    #
    # ```ruby
    # client = Supabase::Postgrest::Client.new(
    #   base_url: "https://project.supabase.co/rest/v1",
    #   headers: { "apikey" => key, "Authorization" => "Bearer #{token}" }
    # )
    #
    # users = client.from("users").select("id, name").eq("status", "active").execute
    # users.data       # => [{ "id" => "...", "name" => "..." }, ...]
    # users.count      # => nil unless a count: was requested
    # ```
    class Client
      attr_reader :base_url, :headers, :schema_name

      # @param base_url [String] full URL to the PostgREST endpoint (e.g. ".../rest/v1")
      # @param schema [String] postgres schema (default "public")
      # @param headers [Hash] static request headers (apikey, Authorization)
      # @param http_client [Faraday::Connection, nil] inject a pre-built Faraday for tests/custom adapters
      # @param verify [Boolean] TLS cert verification
      # @param proxy [String, nil] HTTP proxy URL
      # @param timeout [Numeric, nil] per-request timeout (seconds)
      def initialize(base_url:, schema: "public", headers: {}, http_client: nil,
                     verify: true, proxy: nil, timeout: nil)
        @base_url = base_url.to_s.chomp("/")
        @schema_name = schema
        @headers = build_default_headers(schema, headers)
        @http_client = http_client
        @verify = verify
        @proxy = proxy
        @timeout = timeout
      end

      # Switch schemas. Returns a new client that points at a different postgres schema.
      # @param name [String]
      # @return [Client]
      def schema(name)
        # self.class so async subclasses return an async client, not a sync one.
        self.class.new(
          base_url: @base_url, schema: name,
          headers: @headers.reject { |k, _| %w[Accept-Profile Content-Profile].include?(k) },
          http_client: @http_client, verify: @verify, proxy: @proxy, timeout: @timeout
        )
      end

      # @param table [String]
      # @return [RequestBuilder] entry point for select/insert/update/upsert/delete on this table
      def from(table)
        RequestBuilder.new(session, "#{base_path}/#{table}", @headers.dup)
      end

      alias table from

      # Stored procedure call.
      # @param func [String] function name
      # @param params [Hash] arguments to the function
      # @param count [String, nil] one of "exact" / "planned" / "estimated"
      # @param head [Boolean] HEAD method (count only, no body)
      # @param get [Boolean] GET method (read-only)
      # @return [RPCFilterRequestBuilder]
      def rpc(func, params = {}, count: nil, head: false, get: false)
        method = if head
                   "HEAD"
                 elsif get
                   "GET"
                 else
                   "POST"
                 end

        headers = @headers.dup
        headers["Prefer"] = "count=#{count}" if count

        if %w[HEAD GET].include?(method)
          query = stringify_keys(params)
          body = nil
        else
          query = {}
          body = params
        end

        request = RequestConfig.new(
          session: session, path: "#{base_path}/rpc/#{func}",
          http_method: method, headers: headers, params: query, json: body
        )
        RPCFilterRequestBuilder.new(request)
      end

      private

      def build_default_headers(schema, user_headers)
        defaults = DEFAULT_HEADERS.merge(
          "X-Client-Info" => "supabase-rb/postgrest-rb v#{VERSION}"
        )
        defaults["Accept-Profile"] = schema
        defaults["Content-Profile"] = schema
        defaults.merge(user_headers)
      end

      def session
        @session ||= @http_client || build_session
      end

      def build_session
        Faraday.new(url: @base_url, ssl: { verify: @verify }, proxy: @proxy) do |f|
          if @timeout
            f.options.timeout = @timeout
            f.options.open_timeout = @timeout
          end
          f.adapter Faraday.default_adapter
        end
      end

      def base_path
        URI.parse(@base_url).path.chomp("/")
      end

      def stringify_keys(hash)
        hash.each_with_object({}) { |(k, v), out| out[k.to_s] = v }
      end
    end
  end
end
