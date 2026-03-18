# frozen_string_literal: true

module Supabase
  module Auth
    module Constants
      GOTRUE_URL = "http://localhost:9999"

      DEFAULT_HEADERS = {
        "X-Client-Info" => "gotrue-rb/#{VERSION}"
      }.freeze

      EXPIRY_MARGIN = 10 # seconds

      MAX_RETRIES = 10

      RETRY_INTERVAL = 2 # deciseconds

      STORAGE_KEY = "supabase.auth.token"

      API_VERSION_HEADER_NAME = "X-Supabase-Api-Version"

      API_VERSIONS = {
        "2024-01-01" => {
          "timestamp" => Time.new(2024, 1, 1).to_f,
          "name" => "2024-01-01"
        }.freeze
      }.freeze

      BASE64URL_REGEX = /\A([a-z0-9_-]{4})*($|[a-z0-9_-]{3}$|[a-z0-9_-]{2}$)\z/i
    end
  end
end
