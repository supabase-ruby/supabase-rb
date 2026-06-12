# frozen_string_literal: true

require "async/http/faraday"

module Supabase
  module Auth
    module Async
      # Async counterpart to {Supabase::Auth::Api}.
      #
      # Inherits everything (request dispatch, header merging, error mapping, JSON
      # parsing) and only swaps the Faraday adapter to async-http-faraday so HTTP
      # I/O yields back to the {::Async} reactor instead of blocking the thread.
      #
      # Call sites must run inside an `Async do ... end` block; outside one, the
      # adapter still works but loses the concurrency win.
      class Api < Supabase::Auth::Api
        private

        def build_connection
          Faraday.new(url: @url, ssl: { verify: @verify }, proxy: @proxy) do |f|
            f.response :follow_redirects
            f.response :raise_error
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
