# frozen_string_literal: true

# Convenience requirer for the async tree, mirroring lib/supabase/auth/async.rb.
# Plain `require "supabase/postgrest"` stays free of async-http-faraday so
# sync-only consumers don't pay for the fiber stack.

require_relative "../postgrest"
require_relative "async/client"
