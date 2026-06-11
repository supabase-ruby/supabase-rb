# frozen_string_literal: true

require_relative "api"
require_relative "admin_api"

module Supabase
  module Auth
    module Async
      # Async counterpart to {Supabase::Auth::Client}.
      #
      # Inherits the full public surface (sign_up, sign_in_with_password, get_user,
      # set_session, refresh_session, MFA, identities, JWT claims, subscriptions,
      # etc.) and rewires only the HTTP layer to use async-http-faraday:
      #
      # - `@api` is {Async::Api} instead of {::Supabase::Auth::Api}
      # - `@admin` is {Async::AdminApi} instead of {::Supabase::Auth::AdminApi}
      # - `@mfa` is unchanged — it dispatches through `@client._request`, which
      #   reaches the async `@api` via the parent's `_request` delegate
      #
      # Call sites must run inside an `Async do ... end` block (see docs/async_design.md
      # §4 for usage examples and §6 for fiber/state semantics).
      class Client < Supabase::Auth::Client
        def initialize(url:, headers: {}, **options)
          super
          @api = Api.new(url: @url, headers: @headers, http_client: @http_client, verify: @verify, proxy: @proxy, timeout: @timeout)
          @admin = AdminApi.new(url: @url, headers: @headers, http_client: @http_client, verify: @verify, proxy: @proxy, timeout: @timeout)
        end
      end
    end
  end
end
