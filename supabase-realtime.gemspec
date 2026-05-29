# frozen_string_literal: true

require_relative "lib/supabase/realtime/version"

Gem::Specification.new do |spec|
  spec.name = "supabase-realtime"
  spec.version = Supabase::Realtime::VERSION
  spec.authors = ["Supabase"]
  spec.email = ["support@supabase.io"]

  spec.summary = "Ruby client for the Supabase Realtime (Phoenix Channels) API"
  spec.description = "Phoenix Channels protocol + dispatch for the Supabase Realtime " \
                     "server. Ships with a pluggable Socket interface and an in-memory " \
                     "TestSocket for unit tests. Real WebSocket transports (websocket-" \
                     "client-simple / async-websocket) plug in via the Socket interface."
  spec.homepage = "https://github.com/supabase-rb/client"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/supabase-rb/client"
  spec.metadata["documentation_uri"] = "https://github.com/supabase-rb/client/blob/master/lib/supabase/realtime/README.md"
  spec.metadata["changelog_uri"] = "https://github.com/supabase-rb/client/blob/master/CHANGELOG.md"

  spec.files = Dir["lib/supabase/realtime.rb", "lib/supabase/realtime/**/*.rb",
                   "lib/supabase/realtime/README.md", "LICENSE"]
  spec.require_paths = ["lib"]

  spec.add_development_dependency "rspec", "~> 3.12"
  spec.add_development_dependency "simplecov", "~> 0.22"

  # Real WebSocket transports. Neither is loaded by the default
  # require "supabase/realtime" — users opt in by requiring the adapter file
  # directly, which pulls in the corresponding gem.
  #
  #   require "supabase/realtime/sockets/websocket_client_simple" # sync, threaded
  #   require "supabase/realtime/sockets/async_websocket"         # socketry/async
  spec.add_development_dependency "websocket-client-simple", "~> 0.9"
  spec.add_development_dependency "async-websocket", "~> 0.30"
end
