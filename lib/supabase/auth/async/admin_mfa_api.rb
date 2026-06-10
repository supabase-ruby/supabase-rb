# frozen_string_literal: true

module Supabase
  module Auth
    module Async
      # Async counterpart to {Supabase::Auth::AdminMfaApi}.
      #
      # Behavior is identical — it delegates to the wrapped {AdminApi}'s
      # underscored MFA methods. The wrapped admin uses the async Faraday adapter,
      # so calls inside `Async do ... end` yield to the reactor on I/O.
      class AdminMfaApi < Supabase::Auth::AdminMfaApi
      end
    end
  end
end
