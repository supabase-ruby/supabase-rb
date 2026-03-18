# frozen_string_literal: true

module Supabase
  module Auth
    class AdminApi < Api
      # @param url [String] The GoTrue API base URL
      # @param headers [Hash] Headers including Authorization bearer token
      # @param http_client [Faraday::Connection, nil] Optional custom Faraday client
      def initialize(url:, headers: {}, http_client: nil)
        super(url: url, headers: headers, http_client: http_client)
      end

      # Creates a new user via the admin API.
      # @param attributes [Hash] User attributes (email, password, user_metadata, app_metadata, etc.)
      # @return [Types::User]
      def create_user(attributes)
        data = post("admin/users", body: attributes)
        Types::User.from_hash(data)
      end
    end
  end
end
