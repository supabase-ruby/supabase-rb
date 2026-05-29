# frozen_string_literal: true

require_relative "request"
require_relative "types"

module Supabase
  module Storage
    # Analytics (iceberg) bucket management. Mirrors storage3's
    # `SyncStorageAnalyticsClient` — talks to `{storage_url}/iceberg/bucket`.
    #
    #   client.analytics.create("my-iceberg")
    #   client.analytics.list(limit: 50, sort_column: "name", sort_order: "asc")
    #   client.analytics.delete("my-iceberg")
    class AnalyticsClient
      include Request

      # @param session  [Faraday::Connection]
      # @param base_url [String] storage REST root (".../storage/v1/")
      # @param headers  [Hash]
      def initialize(session, base_url, headers)
        @session  = session
        normalized = base_url.end_with?("/") ? base_url : "#{base_url}/"
        @base_url = "#{normalized}iceberg/"
        @headers  = headers
      end

      def create(bucket_name)
        body = _request(:post, ["bucket"], json: { "name" => bucket_name })
        Types::AnalyticsBucket.from_hash(body)
      end

      # Mirrors py's optional sort/search/pagination params. Nil values are
      # dropped server-side; we also drop them client-side so the URL stays clean.
      def list(limit: nil, offset: nil, sort_column: nil, sort_order: nil, search: nil)
        params = { "limit" => limit, "offset" => offset,
                   "sort_column" => sort_column, "sort_order" => sort_order,
                   "search" => search }.compact
        body = _request(:get, ["bucket"], query: params.empty? ? nil : params)
        Array(body).map { |b| Types::AnalyticsBucket.from_hash(b) }
      end

      def delete(bucket_name)
        body = _request(:delete, ["bucket", bucket_name])
        Types::AnalyticsBucketDeleteResponse.from_hash(body)
      end

      # Python returns a `pyiceberg.RestCatalog`. There is no equivalent Iceberg
      # client in the Ruby ecosystem, so we return the catalog configuration as
      # a plain Hash that a downstream iceberg-ruby (when one exists) can consume.
      # Keeping the public method present mirrors the API surface.
      def catalog(catalog_name, access_key_id:, secret_access_key:)
        service_key = @headers["apiKey"]
        raise Errors::StorageApiError.new("apiKey must be passed in the headers.") if service_key.to_s.empty?

        s3_endpoint = @base_url.sub(%r{iceberg/?\z}, "s3")
        {
          "name"                       => catalog_name,
          "warehouse"                  => catalog_name,
          "uri"                        => @base_url,
          "token"                      => service_key,
          "s3.endpoint"                => s3_endpoint,
          "s3.access-key-id"           => access_key_id,
          "s3.secret-access-key"       => secret_access_key,
          "s3.force-virtual-addressing" => "False"
        }
      end
    end
  end
end
