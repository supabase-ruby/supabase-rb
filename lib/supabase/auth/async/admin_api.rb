# frozen_string_literal: true

require "async/http/faraday"

require_relative "admin_oauth_api"
require_relative "admin_mfa_api"

module Supabase
  module Auth
    module Async
      # Async counterpart to {Supabase::Auth::AdminApi}.
      #
      # Inherits all admin methods (user CRUD, generate_link, invite, MFA admin,
      # OAuth admin) and only swaps the Faraday adapter to async-http-faraday.
      # `admin.oauth` returns an {Async::AdminOAuthApi} and `admin.mfa` returns an
      # {Async::AdminMfaApi} for naming consistency.
      class AdminApi < Supabase::Auth::AdminApi
        def initialize(url:, headers: {}, http_client: nil, verify: true, proxy: nil, timeout: nil)
          super
          @oauth = AdminOAuthApi.new(self)
          @mfa = AdminMfaApi.new(self)
        end

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
