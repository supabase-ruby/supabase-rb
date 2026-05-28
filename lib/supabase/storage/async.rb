# frozen_string_literal: true

# Convenience requirer for the async tree, mirroring lib/supabase/postgrest/async.rb.
# Plain `require "supabase/storage"` stays free of async-http-faraday so sync-only
# consumers don't pay for the fiber stack.

require_relative "../storage"
require_relative "async/client"
