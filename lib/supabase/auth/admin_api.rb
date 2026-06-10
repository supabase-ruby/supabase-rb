# frozen_string_literal: true

require "securerandom"

module Supabase
  module Auth
    # Admin API for managing users with a service role key.
    # Provides CRUD operations on users, link generation, and MFA management.
    class AdminApi < Api
      # @return [AdminOAuthApi] OAuth 2.1 client administration accessor
      attr_reader :oauth

      # @return [AdminMfaApi] MFA administration accessor
      attr_reader :mfa

      # @param url [String] The GoTrue API base URL
      # @param headers [Hash] Headers including Authorization bearer token
      # @param http_client [Faraday::Connection, nil] Optional custom Faraday client
      # @param verify [Boolean] Verify TLS certificates (default true)
      # @param proxy [String, nil] HTTP proxy URL
      # @param timeout [Numeric, nil] Per-request timeout in seconds
      def initialize(url:, headers: {}, http_client: nil, verify: true, proxy: nil, timeout: nil)
        super(url: url, headers: headers, http_client: http_client, verify: verify, proxy: proxy, timeout: timeout)
        @oauth = AdminOAuthApi.new(self)
        @mfa = AdminMfaApi.new(self)
      end

      # Creates a new user via the admin API.
      # @param attributes [Hash] user attributes (email, password, user_metadata, app_metadata, etc.)
      # @return [Types::UserResponse]
      def create_user(attributes)
        data = post("admin/users", body: attributes)
        Helpers.parse_user_response(data)
      end

      # Lists all users.
      # @param page [Integer, nil] page number
      # @param per_page [Integer, nil] users per page
      # @return [Array<Types::User>]
      def list_users(page: nil, per_page: nil)
        params = {}
        params[:page] = page if page
        params[:per_page] = per_page if per_page
        data = get("admin/users", params: params)
        users = data["users"] || []
        users.map { |u| Types::User.from_hash(u) }
      end

      # Gets a user by their ID.
      # @param uid [String] user UUID
      # @return [Types::UserResponse]
      # @raise [ArgumentError] if uid is not a valid UUID
      def get_user_by_id(uid)
        _validate_uuid(uid)
        data = get("admin/users/#{uid}")
        Helpers.parse_user_response(data)
      end

      # Updates a user by their ID.
      # @param uid [String] user UUID
      # @param attributes [Hash] attributes to update
      # @return [Types::UserResponse]
      # @raise [ArgumentError] if uid is not a valid UUID
      def update_user_by_id(uid, attributes)
        _validate_uuid(uid)
        data = put("admin/users/#{uid}", body: attributes)
        Helpers.parse_user_response(data)
      end

      # Deletes a user by their ID.
      # @param uid [String] user UUID
      # @param should_soft_delete [Boolean] soft delete instead of hard delete
      # @raise [ArgumentError] if uid is not a valid UUID
      def delete_user(uid, should_soft_delete: false)
        _validate_uuid(uid)
        _request("DELETE", "admin/users/#{uid}", body: { should_soft_delete: should_soft_delete })
      end

      # Generates email links and OTPs.
      def generate_link(params)
        options = params[:options] || params["options"] || {}
        body = {
          type: params[:type] || params["type"],
          email: params[:email] || params["email"],
          password: params[:password] || params["password"],
          new_email: params[:new_email] || params["new_email"],
          data: options[:data] || options["data"]
        }
        redirect_to = options[:redirect_to] || options["redirect_to"]
        query = {}
        query["redirect_to"] = redirect_to if redirect_to
        data = post("admin/generate_link", body: body, params: query)
        Helpers.parse_link_response(data)
      end

      # Invites a user by email.
      def invite_user_by_email(email, options = {})
        body = { email: email, data: options[:data] || options["data"] }
        redirect_to = options[:redirect_to] || options["redirect_to"]
        query = {}
        query["redirect_to"] = redirect_to if redirect_to
        data = post("invite", body: body, params: query)
        Helpers.parse_user_response(data)
      end

      # Signs out a user by revoking their session via the admin API.
      def sign_out(access_token, scope = "global")
        _request("POST", "logout", jwt: access_token, params: { "scope" => scope }, no_resolve_json: true)
      end

      # Lists MFA factors for a user (admin).
      # @param params [Hash] :user_id (required)
      # @return [Types::AuthMFAAdminListFactorsResponse]
      def _list_factors(params)
        user_id = params[:user_id] || params["user_id"]
        _validate_uuid(user_id)
        data = get("admin/users/#{user_id}/factors")
        Types::AuthMFAAdminListFactorsResponse.from_hash(data)
      end

      # Deletes an MFA factor for a user (admin).
      # @param params [Hash] :user_id and :id (both required)
      # @return [Types::AuthMFAAdminDeleteFactorResponse]
      def _delete_factor(params)
        user_id = params[:user_id] || params["user_id"]
        factor_id = params[:id] || params["id"]
        _validate_uuid(user_id)
        _validate_uuid(factor_id)
        data = delete("admin/users/#{user_id}/factors/#{factor_id}")
        Types::AuthMFAAdminDeleteFactorResponse.from_hash(data)
      end

      # Lists OAuth clients with optional pagination. Only relevant when the OAuth 2.1
      # server is enabled in Supabase Auth.
      # @param params [Hash, Types::PageParams, nil] optional :page and :per_page
      # @return [Types::OAuthClientListResponse]
      def _list_oauth_clients(params = nil)
        query = {}
        if params
          page = params[:page] || params["page"]
          per_page = params[:per_page] || params["per_page"]
          query[:page] = page if page
          query[:per_page] = per_page if per_page
        end

        response = _request("GET", "admin/oauth/clients", params: query, no_resolve_json: true)
        body = response.body.is_a?(String) ? JSON.parse(response.body) : (response.body || {})
        result = Types::OAuthClientListResponse.from_hash(body)

        total = response.headers["x-total-count"] || response.headers["X-Total-Count"]
        result.total = total.to_i if total

        links = response.headers["link"] || response.headers["Link"]
        if links
          links.split(",").each do |link|
            parts = link.split(";")
            next unless parts.length >= 2

            page_match = parts[0].split("page=")
            next unless page_match.length >= 2

            page_num = page_match[1].split("&")[0].sub(/>$/, "").to_i
            rel = parts[1].split("=")[1].to_s.delete('"').strip
            case rel
            when "next" then result.next_page = page_num
            when "last" then result.last_page = page_num
            end
          end
        end

        result
      end

      # Creates a new OAuth client. Only relevant when the OAuth 2.1 server is enabled.
      # @param params [Hash] OAuth client attributes (client_name, redirect_uris, etc.)
      # @return [Types::OAuthClientResponse]
      def _create_oauth_client(params)
        data = post("admin/oauth/clients", body: params)
        Types::OAuthClientResponse.new(client: Types::OAuthClient.from_hash(data))
      end

      # Gets details of a specific OAuth client.
      # @param client_id [String] OAuth client UUID
      # @return [Types::OAuthClientResponse]
      # @raise [ArgumentError] if client_id is not a valid UUID
      def _get_oauth_client(client_id)
        _validate_uuid(client_id)
        data = get("admin/oauth/clients/#{client_id}")
        Types::OAuthClientResponse.new(client: Types::OAuthClient.from_hash(data))
      end

      # Updates an OAuth client.
      # @param client_id [String] OAuth client UUID
      # @param params [Hash] attributes to update
      # @return [Types::OAuthClientResponse]
      # @raise [ArgumentError] if client_id is not a valid UUID
      def _update_oauth_client(client_id, params)
        _validate_uuid(client_id)
        data = put("admin/oauth/clients/#{client_id}", body: params)
        Types::OAuthClientResponse.new(client: Types::OAuthClient.from_hash(data))
      end

      # Deletes an OAuth client.
      # @param client_id [String] OAuth client UUID
      # @raise [ArgumentError] if client_id is not a valid UUID
      def _delete_oauth_client(client_id)
        _validate_uuid(client_id)
        _request("DELETE", "admin/oauth/clients/#{client_id}")
      end

      # Regenerates the secret for an OAuth client.
      # @param client_id [String] OAuth client UUID
      # @return [Types::OAuthClientResponse]
      # @raise [ArgumentError] if client_id is not a valid UUID
      def _regenerate_oauth_client_secret(client_id)
        _validate_uuid(client_id)
        data = post("admin/oauth/clients/#{client_id}/regenerate_secret")
        Types::OAuthClientResponse.new(client: Types::OAuthClient.from_hash(data))
      end
    end
  end
end
