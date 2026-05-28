# frozen_string_literal: true

# Convenience requirer for the async tree, mirroring lib/supabase/{auth,postgrest,storage}/async.rb.
# Plain `require "supabase/functions"` stays free of async-http-faraday so sync-only
# consumers don't pay for the fiber stack.

require_relative "../functions"
require_relative "async/client"
