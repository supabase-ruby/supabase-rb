# frozen_string_literal: true

require "faraday"
require "faraday/multipart"
require "pathname"
require "uri"

require_relative "request"
require_relative "types"
require_relative "utils"

module Supabase
  module Storage
    # All file-level operations scoped to one bucket — upload / download / list /
    # remove / move / copy / info / exists, plus signed/public URL helpers.
    # Mirrors storage3's SyncBucketActionsMixin + SyncBucketProxy.
    #
    # Constructed via {Client#from(bucket_id)}.
    class FileApi
      include Request

      attr_reader :id

      def initialize(id, base_url, headers, session)
        @id       = id
        @base_url = base_url.end_with?("/") ? base_url : "#{base_url}/"
        @headers  = headers
        @session  = session
      end

      # ----- Upload -----

      # @param path [String] destination path within the bucket (e.g. "folder/avatar.png")
      # @param file [String, IO, Pathname] bytes / file-like object / path on disk
      # @param content_type [String, nil]
      # @param cache_control [String, Integer, nil] becomes "max-age=<n>"
      # @param upsert [Boolean]
      # @param metadata [Hash, nil] base64-encoded into the x-metadata header
      # @param headers [Hash, nil] extra HTTP headers to send
      # @return [Types::UploadResponse]
      def upload(path, file, content_type: nil, cache_control: nil, upsert: false, metadata: nil, headers: nil)
        upload_or_update(:post, path, file,
                         content_type: content_type, cache_control: cache_control,
                         upsert: upsert, metadata: metadata, headers: headers)
      end

      def update(path, file, content_type: nil, cache_control: nil, metadata: nil, headers: nil)
        # Per Python: PUT never sends x-upsert.
        upload_or_update(:put, path, file,
                         content_type: content_type, cache_control: cache_control,
                         upsert: false, metadata: metadata, headers: headers, omit_upsert: true)
      end

      # ----- Download -----

      def download(path)
        parts = Utils.relative_path_to_parts(path)
        response = _request(:get, ["object", @id, *parts], raw_response: true)
        response.body
      end

      # ----- List -----

      # @param prefix [String, nil] folder path to list under
      # @param limit  [Integer]
      # @param offset [Integer]
      # @param sort_by [Hash] {column:, order:}
      # @param search [String, nil]
      def list(prefix = nil, limit: nil, offset: nil, sort_by: nil, search: nil)
        body = Types::DEFAULT_SEARCH_OPTIONS.dup
        body["limit"]  = limit  unless limit.nil?
        body["offset"] = offset unless offset.nil?
        body["sortBy"] = stringify_sort_by(sort_by) if sort_by
        body["search"] = search unless search.nil?
        body["prefix"] = prefix || ""
        _request(:post, ["object", "list", @id], json: body, headers: { "Content-Type" => "application/json" })
      end

      # ----- Remove / Move / Copy / Info / Exists -----

      def remove(paths)
        _request(:delete, ["object", @id], json: { "prefixes" => Array(paths) })
      end

      def move(from_path, to_path)
        _request(:post, ["object", "move"],
                 json: { "bucketId" => @id, "sourceKey" => from_path, "destinationKey" => to_path })
      end

      def copy(from_path, to_path)
        _request(:post, ["object", "copy"],
                 json: { "bucketId" => @id, "sourceKey" => from_path, "destinationKey" => to_path })
      end

      def info(path)
        parts = Utils.relative_path_to_parts(path)
        _request(:get, ["object", "info", @id, *parts])
      end

      def exists?(path)
        parts = Utils.relative_path_to_parts(path)
        response = _request(:head, ["object", @id, *parts], raw_response: true)
        response.status == 200
      rescue Errors::StorageApiError
        false
      end

      # ----- Signed URLs -----

      # @param expires_in [Integer] seconds until the URL expires
      # @param download [Boolean, String, nil] `true` to force browser download with the
      #   original filename, a String to override the filename, or nil to leave inline
      # @return [Hash] { "signedURL" => "...", "signedUrl" => "..." }
      def create_signed_url(path, expires_in:, download: nil, transform: nil)
        json = { "expiresIn" => expires_in.to_s }
        download_query = {}
        if download
          json["download"] = download
          download_query["download"] = download == true ? "" : download
        end
        json["transform"] = transform if transform

        parts = Utils.relative_path_to_parts(path)
        body  = _request(:post, ["object", "sign", @id, *parts], json: json)
        wrap_signed_url(body["signedURL"] || body["signedUrl"], download_query)
      end

      def create_signed_urls(paths, expires_in:, download: nil)
        json = { "paths" => Array(paths), "expiresIn" => expires_in.to_s }
        download_query = {}
        if download
          json["download"] = download
          download_query["download"] = download == true ? "" : download
        end

        items = _request(:post, ["object", "sign", @id], json: json)
        Array(items).map do |item|
          wrapped = wrap_signed_url(item["signedURL"] || item["signedUrl"], download_query)
          {
            "error"     => item["error"],
            "path"      => item["path"],
            "signedURL" => wrapped["signedURL"],
            "signedUrl" => wrapped["signedURL"]
          }
        end
      end

      def get_public_url(path, download: nil, transform: nil)
        download_query = {}
        if download
          download_query["download"] = download == true ? "" : download
        end

        render_path = transform ? %w[render image] : %w[object]
        transform_query = transform ? transform.transform_keys(&:to_s).transform_values(&:to_s) : {}
        query = download_query.merge(transform_query)

        parts = Utils.relative_path_to_parts(path)
        Utils.join_url(@base_url, [*render_path, "public", @id, *parts], query)
      end

      def create_signed_upload_url(path, upsert: nil)
        headers = upsert.nil? ? {} : { "x-upsert" => upsert.to_s }
        parts   = Utils.relative_path_to_parts(path)
        body    = _request(:post, ["object", "upload", "sign", @id, *parts], headers: headers)

        signed_url = "#{@base_url.chomp('/')}#{body['url']}"
        token = URI.decode_www_form(URI.parse(signed_url).query.to_s).to_h["token"]
        raise Errors::StorageError, "No token sent by the API" if token.nil? || token.empty?

        Types::SignedUploadURL.new(signed_url: signed_url, token: token, path: path)
      end

      def upload_to_signed_url(path, token:, file:, content_type: nil, cache_control: nil, metadata: nil, headers: nil)
        parts = Utils.relative_path_to_parts(path)
        send_multipart(:put, ["object", "upload", "sign", @id, *parts],
                       file: file, filename: parts.last, content_type: content_type,
                       cache_control: cache_control, upsert: nil, metadata: metadata,
                       extra_headers: headers, query: { "token" => token })
      end

      private

      def upload_or_update(method, path, file, content_type:, cache_control:, upsert:, metadata:, headers:, omit_upsert: false)
        parts = Utils.relative_path_to_parts(path)
        send_multipart(method, ["object", @id, *parts],
                       file: file, filename: parts.last,
                       content_type: content_type, cache_control: cache_control,
                       upsert: omit_upsert ? nil : upsert,
                       metadata: metadata, extra_headers: headers)
      end

      def send_multipart(method, segments, file:, filename:, content_type:, cache_control:, upsert:, metadata:, extra_headers:, query: nil)
        request_headers = {}
        request_headers["cache-control"] = "max-age=#{cache_control}" if cache_control
        request_headers["x-upsert"]      = upsert.to_s unless upsert.nil?
        request_headers.merge!(extra_headers) if extra_headers

        if metadata
          metadata_json = JSON.generate(metadata)
          request_headers["x-metadata"] = [metadata_json].pack("m0")
        end

        ctype = content_type || Types::DEFAULT_FILE_OPTIONS["content-type"]
        upload_io = build_upload_io(file, filename, ctype)

        url = Utils.join_url(@base_url, segments, query)
        merged_headers = @headers.merge(request_headers)
        # Faraday Multipart writes its own multipart Content-Type with boundary; drop ours
        # so it can be regenerated.
        merged_headers.delete("Content-Type")
        merged_headers.delete("content-type")

        form = { file: upload_io }
        form[:cacheControl] = cache_control.to_s if cache_control
        form[:metadata]     = JSON.generate(metadata) if metadata

        # @session is built by Client with `f.request :multipart`, so handing it a
        # Hash body lets the middleware multipart-encode and add the boundary header.
        response = @session.run_request(method, url, form, merged_headers)
        raise_for_status(response)
        parsed = parse_json(response.body) || {}
        Types::UploadResponse.from_hash(path: segments[2..].join("/"), key: parsed["Key"])
      end

      def build_upload_io(file, filename, content_type)
        case file
        when String
          # Treat as raw bytes/text, not a path — call sites that want path semantics
          # pass a Pathname or open the File themselves (matches storage3's bytes/IO contract).
          Faraday::Multipart::FilePart.new(StringIO.new(file), content_type, filename)
        when Pathname
          Faraday::Multipart::FilePart.new(file.to_s, content_type, filename)
        when IO, StringIO
          Faraday::Multipart::FilePart.new(file, content_type, filename)
        else
          if file.respond_to?(:read)
            Faraday::Multipart::FilePart.new(file, content_type, filename)
          else
            raise ArgumentError, "upload `file` must be a String, IO, or Pathname (got #{file.class})"
          end
        end
      end

      def wrap_signed_url(signed_url, download_query)
        return { "signedURL" => nil, "signedUrl" => nil } if signed_url.nil?

        # storage3 strips the leading "/" before joining; we mirror that.
        cleaned = signed_url.sub(%r{^/}, "")
        full = "#{@base_url.chomp('/')}/#{cleaned}"
        full = "#{full}#{full.include?('?') ? '&' : '?'}#{URI.encode_www_form(download_query)}" unless download_query.empty?
        { "signedURL" => full, "signedUrl" => full }
      end

      def stringify_sort_by(sort_by)
        h = sort_by.transform_keys(&:to_s)
        { "column" => h["column"], "order" => h["order"] }
      end
    end
  end
end
