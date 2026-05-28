# frozen_string_literal: true

require "async/http/faraday"
require_relative "../client"

module Supabase
  module Functions
    module Async
      # Async counterpart to {Supabase::Functions::Client}.
      #
      # Inherits the full public surface (invoke, set_auth) and rewires only the
      # Faraday adapter to async-http-faraday so HTTP I/O yields back to the
      # {::Async} reactor instead of blocking the thread.
      #
      # Call sites must run inside an `Async do ... end` block; outside one, the
      # adapter still works but loses the concurrency win.
      #
      #   require "supabase/functions/async"
      #   require "async"
      #
      #   functions = Supabase::Functions::Async::Client.new(
      #     base_url: "https://project.supabase.co/functions/v1",
      #     headers:  { "Authorization" => "Bearer #{key}" }
      #   )
      #
      #   Async do |task|
      #     calls = function_names.map do |name|
      #       task.async { functions.invoke(name, body: { id: 1 }) }
      #     end
      #     calls.map(&:wait)
      #   end
      class Client < Supabase::Functions::Client
        private

        def build_session
          Faraday.new(url: @base_url, ssl: { verify: @verify }, proxy: @proxy) do |f|
            f.options.timeout = @timeout
            f.options.open_timeout = @timeout
            f.adapter :async_http
          end
        end
      end
    end
  end
end
