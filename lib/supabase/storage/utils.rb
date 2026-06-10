# frozen_string_literal: true

require "uri"

module Supabase
  module Storage
    module Utils
      module_function

      # RFC 3986 unreserved set: ALPHA / DIGIT / "-" / "." / "_" / "~"
      # Anything else in a path segment gets percent-encoded byte-by-byte (UTF-8).
      # This matches yarl's path-segment encoding used by storage3 / supabase-py.
      RFC3986_UNRESERVED = /[^A-Za-z0-9\-._~]/n.freeze
      private_constant :RFC3986_UNRESERVED

      # Splits a relative storage path into its path segments, dropping a leading
      # `/` if the caller supplied one. Mirrors storage3.utils.relative_path_to_parts.
      #
      #   relative_path_to_parts("folder/avatar.png") # => ["folder", "avatar.png"]
      #   relative_path_to_parts("/folder/x.png")     # => ["folder", "x.png"]
      def relative_path_to_parts(path)
        path.to_s.split("/").reject(&:empty?)
      end

      # Percent-encode a single path segment per RFC 3986 (unreserved set only).
      # Notably: space → "%20" (not "+"), "+" → "%2B", "/" → "%2F".
      # `URI.encode_www_form_component` cannot be used here — it follows
      # application/x-www-form-urlencoded, which mis-encodes spaces and "+".
      def rfc3986_encode_segment(segment)
        segment.to_s.b.gsub(RFC3986_UNRESERVED) { |b| format("%%%02X", b.unpack1("C")) }
      end

      # URL-encode each path segment so user-supplied filenames don't break the URL.
      def encode_segments(parts)
        parts.map { |p| rfc3986_encode_segment(p) }
      end

      # Join the (already-trailing-slashed) base URL with the given path segments and
      # an optional query Hash. Used so `_request` never has to concat strings by hand.
      def join_url(base_url, segments, query = nil)
        path = encode_segments(segments).join("/")
        url = "#{base_url.chomp('/')}/#{path}"
        return url if query.nil? || query.empty?

        "#{url}?#{URI.encode_www_form(query)}"
      end
    end
  end
end
