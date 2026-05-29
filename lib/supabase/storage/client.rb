# frozen_string_literal: true

require "faraday"
require "faraday/multipart"

require_relative "bucket_api"
require_relative "file_api"
require_relative "analytics"
require_relative "vectors"
require_relative "version"

module Supabase
  module Storage
    # Sync Storage client. Constructed once per project; reused across requests.
    #
    #   client = Supabase::Storage::Client.new(
    #     base_url: "https://project.supabase.co/storage/v1",
    #     headers:  { "apikey" => key, "Authorization" => "Bearer #{token}" }
    #   )
    #
    #   client.list_buckets               # bucket-management surface
    #   client.from("avatars").upload(...) # file-level surface, scoped to one bucket
    class Client < BucketApi
      attr_reader :base_url, :headers

      # @param base_url [String] storage REST endpoint (e.g. ".../storage/v1")
      # @param headers  [Hash] static request headers (apikey, Authorization)
      # @param http_client [Faraday::Connection, nil] inject a pre-built Faraday for tests
      # @param verify [Boolean] TLS cert verification
      # @param proxy [String, nil]
      # @param timeout [Numeric, nil]
      def initialize(base_url:, headers: {}, http_client: nil, verify: true, proxy: nil, timeout: nil)
        @verify  = verify
        @proxy   = proxy
        @timeout = timeout
        @http_client = http_client
        normalized = base_url.to_s
        normalized = "#{normalized}/" unless normalized.end_with?("/")

        default_headers = {
          "X-Client-Info" => "supabase-rb/storage-rb v#{VERSION}"
        }.merge(headers)

        super(http_client || build_session(normalized), normalized, default_headers)
      end

      # Return a {FileApi} scoped to the given bucket.
      def from(bucket_id)
        FileApi.new(bucket_id, @base_url, @headers, @session)
      end

      alias bucket from

      # Iceberg / analytics bucket management. Mirrors storage3's
      # `SyncStorageClient#analytics`.
      def analytics
        @analytics ||= AnalyticsClient.new(@session, @base_url, @headers)
      end

      # Vector bucket / index / record management. Mirrors storage3's
      # `SyncStorageClient#vectors`.
      def vectors
        @vectors ||= VectorsClient.new(@session, @base_url, @headers)
      end

      private

      def build_session(base_url)
        Faraday.new(url: base_url, ssl: { verify: @verify }, proxy: @proxy) do |f|
          f.request :multipart
          if @timeout
            f.options.timeout = @timeout
            f.options.open_timeout = @timeout
          end
          f.adapter Faraday.default_adapter
        end
      end
    end
  end
end
