# frozen_string_literal: true

module Supabase
  module Storage
    module Types
      # Matches storage3's DEFAULT_SEARCH_OPTIONS — sent in the list() body when the
      # caller doesn't override individual fields.
      DEFAULT_SEARCH_OPTIONS = {
        "limit"  => 100,
        "offset" => 0,
        "sortBy" => { "column" => "name", "order" => "asc" }
      }.freeze

      # Matches storage3's DEFAULT_FILE_OPTIONS — base headers/form fields for upload.
      DEFAULT_FILE_OPTIONS = {
        "cache-control" => "3600",
        "content-type"  => "text/plain;charset=UTF-8",
        "x-upsert"      => "false"
      }.freeze

      # Returned by list_buckets / get_bucket. Mirrors storage3's BaseBucket fields.
      Bucket = Struct.new(
        :id, :name, :owner, :public, :file_size_limit, :allowed_mime_types,
        :created_at, :updated_at, :type,
        keyword_init: true
      ) do
        def self.from_hash(hash)
          return nil if hash.nil?

          h = hash.transform_keys(&:to_s)
          new(
            id:                 h["id"],
            name:               h["name"],
            owner:              h["owner"],
            public:             h["public"],
            file_size_limit:    h["file_size_limit"],
            allowed_mime_types: h["allowed_mime_types"],
            created_at:         h["created_at"],
            updated_at:         h["updated_at"],
            type:               h["type"]
          )
        end
      end

      # Returned by upload/update. Python exposes :path/:full_path/:fullPath; we keep
      # both snake_case and camelCase aliases so call sites that follow Python docs work.
      UploadResponse = Struct.new(:path, :full_path, :key, keyword_init: true) do
        alias_method :fullPath, :full_path # rubocop:disable Naming/MethodName

        def self.from_hash(path:, key:)
          new(path: path, full_path: key, key: key)
        end
      end

      # Returned by create_signed_upload_url.
      SignedUploadURL = Struct.new(:signed_url, :token, :path, keyword_init: true) do
        alias_method :signedUrl, :signed_url # rubocop:disable Naming/MethodName
      end

      # --- list_v2 -----------------------------------------------------------

      SearchV2Object = Struct.new(:id, :name, :updated_at, :created_at, :metadata, :key, keyword_init: true) do
        def self.from_hash(hash)
          return nil if hash.nil?

          h = hash.transform_keys(&:to_s)
          new(id: h["id"], name: h["name"],
              updated_at: h["updated_at"], created_at: h["created_at"],
              metadata: h["metadata"], key: h["key"])
        end
      end

      SearchV2Folder = Struct.new(:key, :name, :created_at, :updated_at, keyword_init: true) do
        def self.from_hash(hash)
          return nil if hash.nil?

          h = hash.transform_keys(&:to_s)
          new(key: h["key"], name: h["name"],
              created_at: h["created_at"], updated_at: h["updated_at"])
        end
      end

      SearchV2Result = Struct.new(:has_next, :folders, :objects, :next_cursor, keyword_init: true) do
        alias_method :hasNext, :has_next       # rubocop:disable Naming/MethodName
        alias_method :nextCursor, :next_cursor # rubocop:disable Naming/MethodName

        def self.from_hash(hash)
          return nil if hash.nil?

          h = hash.transform_keys(&:to_s)
          new(
            has_next:    h["hasNext"],
            folders:     Array(h["folders"]).map { |f| SearchV2Folder.from_hash(f) },
            objects:     Array(h["objects"]).map { |o| SearchV2Object.from_hash(o) },
            next_cursor: h["nextCursor"]
          )
        end
      end

      # --- Analytics ---------------------------------------------------------

      # Returned by analytics.create / analytics.list. Mirrors storage3's
      # `AnalyticsBucket` pydantic model.
      AnalyticsBucket = Struct.new(:name, :type, :format, :created_at, :updated_at, keyword_init: true) do
        def self.from_hash(hash)
          return nil if hash.nil?

          h = hash.transform_keys(&:to_s)
          new(name: h["name"], type: h["type"], format: h["format"],
              created_at: h["created_at"], updated_at: h["updated_at"])
        end
      end

      AnalyticsBucketDeleteResponse = Struct.new(:message, keyword_init: true) do
        def self.from_hash(hash)
          return nil if hash.nil?

          new(message: hash.transform_keys(&:to_s)["message"])
        end
      end

      # --- Vectors -----------------------------------------------------------

      VectorBucketEncryptionConfiguration = Struct.new(:kms_key_arn, :sse_type, keyword_init: true) do
        def self.from_hash(hash)
          return nil if hash.nil?

          h = hash.transform_keys(&:to_s)
          new(kms_key_arn: h["kmsKeyArn"], sse_type: h["sseType"])
        end
      end

      VectorBucket = Struct.new(:vector_bucket_name, :creation_time, :encryption_configuration, keyword_init: true) do
        def self.from_hash(hash)
          return nil if hash.nil?

          h = hash.transform_keys(&:to_s)
          new(
            vector_bucket_name:       h["vectorBucketName"],
            creation_time:            h["creationTime"],
            encryption_configuration: VectorBucketEncryptionConfiguration.from_hash(h["encryptionConfiguration"])
          )
        end
      end

      GetVectorBucketResponse = Struct.new(:vector_bucket, keyword_init: true) do
        def self.from_hash(hash)
          return nil if hash.nil?

          new(vector_bucket: VectorBucket.from_hash(hash.transform_keys(&:to_s)["vectorBucket"]))
        end
      end

      ListVectorBucketsResponse = Struct.new(:vector_buckets, :next_token, keyword_init: true) do
        def self.from_hash(hash)
          return nil if hash.nil?

          h = hash.transform_keys(&:to_s)
          items = Array(h["vectorBuckets"]).map { |b| { name: b["vectorBucketName"] } }
          new(vector_buckets: items, next_token: h["nextToken"])
        end
      end

      VectorIndex = Struct.new(:index_name, :bucket_name, :data_type, :dimension,
                               :distance_metric, :metadata, :creation_time, keyword_init: true) do
        def self.from_hash(hash)
          return nil if hash.nil?

          h = hash.transform_keys(&:to_s)
          new(
            index_name:       h["indexName"],
            bucket_name:      h["vectorBucketName"],
            data_type:        h["dataType"],
            dimension:        h["dimension"],
            distance_metric:  h["distanceMetric"],
            metadata:         h["metadataConfiguration"],
            creation_time:    h["creationTime"]
          )
        end
      end

      GetVectorIndexResponse = Struct.new(:index, keyword_init: true) do
        def self.from_hash(hash)
          return nil if hash.nil?

          new(index: VectorIndex.from_hash(hash.transform_keys(&:to_s)["index"]))
        end
      end

      ListVectorIndexesResponse = Struct.new(:indexes, :next_token, keyword_init: true) do
        def self.from_hash(hash)
          return nil if hash.nil?

          h = hash.transform_keys(&:to_s)
          indexes = Array(h["indexes"]).map { |i| { index_name: i["indexName"] } }
          new(indexes: indexes, next_token: h["nextToken"])
        end
      end

      # Matched/returned vector. Mirrors `VectorMatch` in storage3.
      VectorMatch = Struct.new(:key, :data, :distance, :metadata, keyword_init: true) do
        def self.from_hash(hash)
          return nil if hash.nil?

          h = hash.transform_keys(&:to_s)
          new(key: h["key"], data: h["data"], distance: h["distance"], metadata: h["metadata"])
        end
      end

      GetVectorsResponse = Struct.new(:vectors, keyword_init: true) do
        def self.from_hash(hash)
          return nil if hash.nil?

          new(vectors: Array(hash.transform_keys(&:to_s)["vectors"]).map { |v| VectorMatch.from_hash(v) })
        end
      end

      ListVectorsResponse = Struct.new(:vectors, :next_token, keyword_init: true) do
        def self.from_hash(hash)
          return nil if hash.nil?

          h = hash.transform_keys(&:to_s)
          new(vectors: Array(h["vectors"]).map { |v| VectorMatch.from_hash(v) }, next_token: h["nextToken"])
        end
      end

      QueryVectorsResponse = Struct.new(:vectors, keyword_init: true) do
        def self.from_hash(hash)
          return nil if hash.nil?

          new(vectors: Array(hash.transform_keys(&:to_s)["vectors"]).map { |v| VectorMatch.from_hash(v) })
        end
      end
    end
  end
end
