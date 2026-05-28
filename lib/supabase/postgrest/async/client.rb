# frozen_string_literal: true

require "async/http/faraday"
require_relative "../client"

module Supabase
  module Postgrest
    module Async
      # Async counterpart to {Supabase::Postgrest::Client}.
      #
      # Inherits the full public surface (from, table, rpc, schema) and rewires
      # only the Faraday adapter to async-http-faraday so HTTP I/O yields back
      # to the {::Async} reactor instead of blocking the thread.
      #
      # The request builders (RequestBuilder / FilterRequestBuilder / etc.) are
      # transport-agnostic and reused unchanged — they speak to whatever Faraday
      # connection the client hands them.
      #
      # Call sites must run inside an `Async do ... end` block; outside one, the
      # adapter still works but loses the concurrency win.
      #
      #   require "supabase/postgrest/async"
      #   require "async"
      #
      #   client = Supabase::Postgrest::Async::Client.new(
      #     base_url: "https://project.supabase.co/rest/v1",
      #     headers:  { "apikey" => key }
      #   )
      #
      #   Async do |task|
      #     users_task = task.async { client.from("users").select("*").execute }
      #     posts_task = task.async { client.from("posts").select("*").execute }
      #     users, posts = users_task.wait, posts_task.wait
      #   end
      class Client < Supabase::Postgrest::Client
        private

        def build_session
          Faraday.new(url: @base_url, ssl: { verify: @verify }, proxy: @proxy) do |f|
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
