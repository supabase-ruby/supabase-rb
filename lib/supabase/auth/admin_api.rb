# frozen_string_literal: true

require "securerandom"

module Supabase
  module Auth
    # Admin API for managing users with a service role key.
    # Provides CRUD operations on users, link generation, and MFA management.
    class AdminApi < Api
      # @param url [String] The GoTrue API base URL
      # @param headers [Hash] Headers including Authorization bearer token
      # @param http_client [Faraday::Connection, nil] Optional custom Faraday client
      def initialize(url:, headers: {}, http_client: nil)
        super(url: url, headers: headers, http_client: http_client)
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
        delete("admin/users/#{uid}", params: {})
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
        }.compact
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
        post("logout", body: {}, headers: { "Authorization" => "Bearer #{access_token}" }, params: { "scope" => scope })
      end

      # Lists MFA factors for a user (admin).
      def _list_factors(params)
        user_id = params[:user_id] || params["user_id"]
        _validate_uuid(user_id)
        data = get("admin/users/#{user_id}/factors")
        data
      end

      # Deletes an MFA factor for a user (admin).
      def _delete_factor(params)
        user_id = params[:user_id] || params["user_id"]
        factor_id = params[:id] || params["id"]
        _validate_uuid(user_id)
        _validate_uuid(factor_id)
        delete("admin/users/#{user_id}/factors/#{factor_id}")
      end
    end
  end
end
