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
  spec.homepage = "https://github.com/supabase/supabase-rb"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/supabase/supabase-rb"
  spec.metadata["changelog_uri"] = "https://github.com/supabase/supabase-rb/blob/main/CHANGELOG.md"

  spec.files = Dir["lib/**/*.rb", "LICENSE", "README.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "faraday", "~> 2.0"
  spec.add_dependency "faraday-multipart", "~> 1.0"
  spec.add_dependency "jwt", "~> 2.8"

  spec.add_development_dependency "rspec", "~> 3.12"
  spec.add_development_dependency "simplecov", "~> 0.22"
  spec.add_development_dependency "webmock", "~> 3.19"
  spec.add_development_dependency "faker", "~> 3.2"
end
