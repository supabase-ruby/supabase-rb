# frozen_string_literal: true

require_relative "request"
require_relative "types"
require_relative "errors"

module Supabase
  module Storage
    # Vector bucket / index / record management. Mirrors storage3's
    # `SyncStorageVectorsClient`. All endpoints are POSTs to actions under
    # `{storage_url}/vector/...`.
    #
    #   vectors = client.vectors
    #   vectors.create_bucket("docs")
    #   vectors.from("docs").create_index("paragraphs", 1536, "cosine", "float32")
    #   vectors.from("docs").index("paragraphs").put([{ key: "p1", data: { float32: [...] } }])
    class VectorsClient
      include Request

      def initialize(session, base_url, headers)
        @session  = session
        normalized = base_url.end_with?("/") ? base_url : "#{base_url}/"
        @base_url = "#{normalized}vector/"
        @headers  = headers
      end

      # Scope subsequent index/record operations to a particular vector bucket.
      def from(bucket_name)
        VectorBucketScope.new(self, bucket_name)
      end

      alias from_ from

      def create_bucket(bucket_name)
        _request(:post, ["CreateVectorBucket"], json: { "vectorBucketName" => bucket_name })
        nil
      end

      # Returns nil if the bucket doesn't exist (matches py's swallow of
      # StorageApiError). Any other API failure still surfaces.
      def get_bucket(bucket_name)
        body = _request(:post, ["GetVectorBucket"], json: { "vectorBucketName" => bucket_name })
        Types::GetVectorBucketResponse.from_hash(body)
      rescue Errors::StorageApiError
        nil
      end

      def list_buckets(prefix: nil, max_results: nil, next_token: nil)
        json = { "prefix" => prefix, "maxResults" => max_results, "nextToken" => next_token }.compact
        body = _request(:post, ["ListVectorBuckets"], json: json)
        Types::ListVectorBucketsResponse.from_hash(body)
      end

      def delete_bucket(bucket_name)
        _request(:post, ["DeleteVectorBucket"], json: { "vectorBucketName" => bucket_name })
        nil
      end

      # Exposed so the scope classes can reuse our wired-up session/headers
      # without re-implementing `_request`. Not part of the public API.
      def send_action(path:, json: nil) # :nodoc:
        _request(:post, [path], json: json)
      end
    end

    # A bucket-scoped facade. Mirrors storage3's `SyncVectorBucketScope`.
    class VectorBucketScope
      def initialize(vectors_client, bucket_name)
        @client      = vectors_client
        @bucket_name = bucket_name
      end

      def create_index(index_name, dimension, distance_metric, data_type, metadata: nil)
        json = with_metadata(
          "indexName"             => index_name,
          "dimension"             => dimension,
          "distanceMetric"        => distance_metric,
          "dataType"              => data_type,
          "metadataConfiguration" => metadata
        )
        @client.send_action(path: "CreateIndex", json: json)
        nil
      end

      def get_index(index_name)
        body = @client.send_action(path: "GetIndex", json: with_metadata("indexName" => index_name))
        Types::GetVectorIndexResponse.from_hash(body)
      rescue Errors::StorageApiError
        nil
      end

      def list_indexes(next_token: nil, max_results: nil, prefix: nil)
        json = with_metadata("next_token" => next_token, "max_results" => max_results, "prefix" => prefix)
        body = @client.send_action(path: "ListIndexes", json: json)
        Types::ListVectorIndexesResponse.from_hash(body)
      end

      def delete_index(index_name)
        @client.send_action(path: "DeleteIndex", json: with_metadata("indexName" => index_name))
        nil
      end

      def index(index_name)
        VectorIndexScope.new(@client, @bucket_name, index_name)
      end

      private

      # Drops nil values and stamps the vector bucket name onto every request,
      # matching the py helper of the same name.
      def with_metadata(extra = {})
        { "vectorBucketName" => @bucket_name }.merge(extra).reject { |_, v| v.nil? }
      end
    end

    # A bucket+index-scoped facade for record-level operations. Mirrors
    # storage3's `SyncVectorIndexScope`.
    class VectorIndexScope
      VECTOR_BATCH_MIN = 1
      VECTOR_BATCH_MAX = 500

      def initialize(vectors_client, bucket_name, index_name)
        @client      = vectors_client
        @bucket_name = bucket_name
        @index_name  = index_name
      end

      def put(vectors)
        # Accept either Hashes or VectorMatch-like Structs; serialize hashes
        # directly so callers can pass plain `{ key:, data:, metadata: }`.
        serialized = Array(vectors).map { |v| v.respond_to?(:to_h) ? v.to_h : v }
                                   .map { |h| h.reject { |_, val| val.nil? } }
        @client.send_action(path: "PutVectors", json: with_metadata("vectors" => serialized))
        nil
      end

      def get(*keys, return_data: true, return_metadata: true)
        json = with_metadata("keys" => keys, "returnData" => return_data, "returnMetadata" => return_metadata)
        body = @client.send_action(path: "GetVectors", json: json)
        Types::GetVectorsResponse.from_hash(body)
      end

      def list(max_results: nil, next_token: nil, return_data: true, return_metadata: true,
               segment_count: nil, segment_index: nil)
        json = with_metadata(
          "maxResults"     => max_results,
          "nextToken"      => next_token,
          "returnData"     => return_data,
          "returnMetadata" => return_metadata,
          "segmentCount"   => segment_count,
          "segmentIndex"   => segment_index
        )
        body = @client.send_action(path: "ListVectors", json: json)
        Types::ListVectorsResponse.from_hash(body)
      end

      def query(query_vector, top_k: nil, filter: nil, return_distance: true, return_metadata: true)
        json = with_metadata(
          "queryVector"     => query_vector,
          "topK"            => top_k,
          "filter"          => filter,
          "returnDistance"  => return_distance,
          "returnMetadata"  => return_metadata
        )
        body = @client.send_action(path: "QueryVectors", json: json)
        Types::QueryVectorsResponse.from_hash(body)
      end

      def delete(keys)
        keys = Array(keys)
        if keys.size < VECTOR_BATCH_MIN || keys.size > VECTOR_BATCH_MAX
          raise Errors::VectorBucketException, "Keys batch size must be between #{VECTOR_BATCH_MIN} and #{VECTOR_BATCH_MAX}."
        end

        @client.send_action(path: "DeleteVectors", json: with_metadata("keys" => keys))
        nil
      end

      private

      def with_metadata(extra = {})
        {
          "vectorBucketName" => @bucket_name,
          "indexName"        => @index_name
        }.merge(extra).reject { |_, v| v.nil? }
      end
    end
  end
end
