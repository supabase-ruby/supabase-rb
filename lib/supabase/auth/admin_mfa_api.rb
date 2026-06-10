# frozen_string_literal: true

module Supabase
  module Auth
    # Admin MFA namespace. Mirrors supabase-py's SyncGoTrueAdminMFAAPI.
    # Accessed via {AdminApi#mfa}; delegates to the underscored implementations
    # on AdminApi (same pattern as {AdminOAuthApi} / {AdminApi#oauth}).
    class AdminMfaApi
      # @param admin [AdminApi]
      def initialize(admin)
        @admin = admin
      end

      # Lists MFA factors for a user.
      # @param user_id [String] user UUID
      # @return [Types::AuthMFAAdminListFactorsResponse]
      def list_factors(user_id:)
        @admin._list_factors(user_id: user_id)
      end

      # Deletes an MFA factor for a user.
      # @param user_id [String] user UUID
      # @param id [String] factor UUID
      # @return [Types::AuthMFAAdminDeleteFactorResponse]
      def delete_factor(user_id:, id:)
        @admin._delete_factor(user_id: user_id, id: id)
      end
    end
  end
end
