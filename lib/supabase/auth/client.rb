# frozen_string_literal: true

module Supabase
  module Auth
    class Client
      DEFAULT_OPTIONS = {
        auto_refresh_token: true,
        persist_session: true,
        detect_session_in_url: true,
        flow_type: :implicit
      }.freeze

      attr_reader :url, :headers

      # @param url [String] The GoTrue API URL
      # @param headers [Hash] Headers to include on every request (e.g., apikey)
      # @param options [Hash] Configuration options
      # @option options [Boolean] :auto_refresh_token (true) Automatically refresh token before expiry
      # @option options [Boolean] :persist_session (true) Persist session to storage
      # @option options [Boolean] :detect_session_in_url (true) Detect OAuth session in URL
      # @option options [Object] :http_client Custom Faraday client instance
      # @option options [Symbol] :flow_type (:implicit) Auth flow type (:implicit or :pkce)
      def initialize(url:, headers: {}, **options)
        @url = url
        @headers = headers
        @options = DEFAULT_OPTIONS.merge(options)
        @auto_refresh_token = @options[:auto_refresh_token]
        @persist_session = @options[:persist_session]
        @detect_session_in_url = @options[:detect_session_in_url]
        @http_client = @options[:http_client]
        @flow_type = @options[:flow_type]
        @current_session = nil
      end

      # @return [Boolean]
      def auto_refresh_token?
        @auto_refresh_token
      end

      # @return [Boolean]
      def persist_session?
        @persist_session
      end

      # @return [Boolean]
      def detect_session_in_url?
        @detect_session_in_url
      end

      # @return [Symbol]
      def flow_type
        @flow_type
      end
    end
  end
end
