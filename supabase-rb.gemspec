# frozen_string_literal: true

require_relative "lib/supabase/version"

Gem::Specification.new do |spec|
  spec.name = "supabase-rb"
  spec.version = Supabase::VERSION
  spec.authors = ["Supabase"]
  spec.email = ["support@supabase.io"]

  spec.summary = "Ruby client for Supabase"
  spec.description = "Ruby client for Supabase: Auth, PostgREST, Storage, Edge Functions, and " \
                     "Realtime exposed through a single Supabase.create_client(supabase_url:, " \
                     "supabase_key:) factory, mirroring supabase-py's create_client()."
  spec.homepage = "https://github.com/supabase-ruby/supabase-rb"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/supabase-ruby/supabase-rb"
  spec.metadata["documentation_uri"] = "https://github.com/supabase-ruby/supabase-rb/blob/master/lib/supabase/README.md"
  spec.metadata["changelog_uri"] = "https://github.com/supabase-ruby/supabase-rb/blob/master/CHANGELOG.md"

  spec.files = Dir[
    "lib/supabase.rb",
    "lib/supabase-auth.rb",
    "lib/supabase/**/*.rb",
    "lib/supabase/README.md",
    "lib/supabase/**/README.md",
    "LICENSE"
  ]
  spec.require_paths = ["lib"]

  spec.add_dependency "faraday", "~> 2.0"
  spec.add_dependency "faraday-multipart", "~> 1.0"
  spec.add_dependency "jwt", "~> 2.8"

  spec.add_development_dependency "rspec", "~> 3.12"
  spec.add_development_dependency "simplecov", "~> 0.22"
  spec.add_development_dependency "webmock", "~> 3.19"
  spec.add_development_dependency "faker", "~> 3.2"
  spec.add_development_dependency "async", "~> 2.0"
  spec.add_development_dependency "async-http-faraday", "~> 0.20"
  spec.add_development_dependency "websocket-client-simple", "~> 0.9"
  spec.add_development_dependency "async-websocket", "~> 0.30"
end
