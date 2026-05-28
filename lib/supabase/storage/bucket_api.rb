# frozen_string_literal: true

require_relative "request"
require_relative "types"
require_relative "utils"

module Supabase
  module Storage
    # The bucket-management half of the storage client — list / get / create / update /
    # empty / delete on bucket records. Mirrors storage3's SyncStorageBucketAPI.
    #
    # {Client} inherits from this; callers don't construct BucketApi directly.
    class BucketApi
      include Request

      # @param session  [Faraday::Connection]
      # @param base_url [String] storage REST endpoint, e.g. "https://x.supabase.co/storage/v1/"
      # @param headers  [Hash] static request headers (apikey, Authorization, etc.)
      def initialize(session, base_url, headers)
        @session  = session
        @base_url = base_url.end_with?("/") ? base_url : "#{base_url}/"
        @headers  = headers
      end

      def list_buckets
        body = _request(:get, ["bucket"])
        Array(body).map { |b| Types::Bucket.from_hash(b) }
      end

      def get_bucket(id)
        Types::Bucket.from_hash(_request(:get, ["bucket", id]))
      end

      # @param id [String]
      # @param name [String, nil] defaults to id
      # @param public [Boolean, nil]
      # @param file_size_limit [Integer, nil]
      # @param allowed_mime_types [Array<String>, nil]
      # @return [Hash] the raw response body
      def create_bucket(id, name: nil, public: nil, file_size_limit: nil, allowed_mime_types: nil)
        json = { "id" => id, "name" => name || id }
        json["public"]             = public             unless public.nil?
        json["file_size_limit"]    = file_size_limit    unless file_size_limit.nil?
        json["allowed_mime_types"] = allowed_mime_types unless allowed_mime_types.nil?
        _request(:post, ["bucket"], json: json)
      end

      def update_bucket(id, public: nil, file_size_limit: nil, allowed_mime_types: nil)
        json = { "id" => id, "name" => id }
        json["public"]             = public             unless public.nil?
        json["file_size_limit"]    = file_size_limit    unless file_size_limit.nil?
        json["allowed_mime_types"] = allowed_mime_types unless allowed_mime_types.nil?
        _request(:put, ["bucket", id], json: json)
      end

      def empty_bucket(id)
        _request(:post, ["bucket", id, "empty"], json: {})
      end

      def delete_bucket(id)
        _request(:delete, ["bucket", id], json: {})
      end
    end
  end
end
