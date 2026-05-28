# frozen_string_literal: true

require "async/http/faraday"
require_relative "../client"

module Supabase
  module Storage
    module Async
      # Async counterpart to {Supabase::Storage::Client}.
      #
      # Inherits the full public surface (list_buckets, get_bucket, create_bucket,
      # update_bucket, empty_bucket, delete_bucket, from/bucket → FileApi) and
      # rewires only the Faraday adapter to async-http-faraday so HTTP I/O yields
      # back to the {::Async} reactor instead of blocking the thread.
      #
      # BucketApi and FileApi are transport-agnostic — they speak to whatever
      # Faraday connection the client hands them, so neither has an async twin.
      #
      # Call sites must run inside an `Async do ... end` block; outside one, the
      # adapter still works but loses the concurrency win.
      #
      #   require "supabase/storage/async"
      #   require "async"
      #
      #   storage = Supabase::Storage::Async::Client.new(
      #     base_url: "https://project.supabase.co/storage/v1",
      #     headers:  { "apikey" => key }
      #   )
      #
      #   Async do |task|
      #     uploads = files.map do |f|
      #       task.async { storage.from("avatars").upload(f.name, f.bytes) }
      #     end
      #     uploads.map(&:wait)
      #   end
      class Client < Supabase::Storage::Client
        private

        def build_session(base_url)
          Faraday.new(url: base_url, ssl: { verify: @verify }, proxy: @proxy) do |f|
            f.request :multipart
            if @timeout
              f.options.timeout = @timeout
              f.options.open_timeout = @timeout
            end
            f.adapter :async_http
          end
        end
      end
    end
  end
end
