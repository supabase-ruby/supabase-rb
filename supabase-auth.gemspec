# frozen_string_literal: true

require_relative "lib/supabase/auth/version"

Gem::Specification.new do |spec|
  spec.name = "supabase-auth"
  spec.version = Supabase::Auth::VERSION
  spec.authors = ["Supabase"]
  spec.email = ["support@supabase.io"]

  spec.summary = "Ruby client for Supabase Auth (GoTrue API)"
  spec.description = "A Ruby gem implementing a client for Supabase Auth (GoTrue API), " \
                     "with adaptations for Ruby idioms."
  spec.homepage = "https://github.com/supabase-rb/client"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/supabase-rb/client"
  spec.metadata["documentation_uri"] = "https://github.com/supabase-rb/client/blob/master/lib/supabase/auth/README.md"
  spec.metadata["changelog_uri"] = "https://github.com/supabase-rb/client/blob/master/CHANGELOG.md"

  spec.files = Dir[
    "lib/supabase-auth.rb",
    "lib/supabase/auth.rb",
    "lib/supabase/auth/**/*.rb",
    "lib/supabase/auth/README.md",
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

  # Spike: async variant exploration (see lib/supabase/auth/async/, docs/async_design.md).
  # Not loaded by lib/supabase/auth.rb — production sync gem stays free of async deps.
  spec.add_development_dependency "async", "~> 2.0"
  spec.add_development_dependency "async-http-faraday", "~> 0.20"
end
