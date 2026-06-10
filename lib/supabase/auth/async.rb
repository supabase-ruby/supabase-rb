# frozen_string_literal: true

# Convenience loader for the async variant. Production sync users do NOT need this —
# `require "supabase/auth"` ships zero async transitive deps. Users who want the
# async variant add `gem "async"` and `gem "async-http-faraday"` to their Gemfile,
# then `require "supabase/auth/async"`.
#
# See docs/async_design.md for the full architecture rationale.

require_relative "../auth"
require_relative "async/api"
require_relative "async/admin_oauth_api"
require_relative "async/admin_mfa_api"
require_relative "async/admin_api"
require_relative "async/client"
