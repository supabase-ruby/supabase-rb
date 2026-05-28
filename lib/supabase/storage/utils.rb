# frozen_string_literal: true

require "uri"

module Supabase
  module Storage
    module Utils
      module_function

      # Splits a relative storage path into its path segments, dropping a leading
      # `/` if the caller supplied one. Mirrors storage3.utils.relative_path_to_parts.
      #
      #   relative_path_to_parts("folder/avatar.png") # => ["folder", "avatar.png"]
      #   relative_path_to_parts("/folder/x.png")     # => ["folder", "x.png"]
      def relative_path_to_parts(path)
        path.to_s.split("/").reject(&:empty?)
      end

      # URL-encode each path segment so user-supplied filenames don't break the URL.
      def encode_segments(parts)
        parts.map { |p| URI.encode_www_form_component(p) }
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
