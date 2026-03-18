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
    end
  end
end
