# frozen_string_literal: true

require_relative "lib/supabase/postgrest/version"

Gem::Specification.new do |spec|
  spec.name = "supabase-postgrest"
  spec.version = Supabase::Postgrest::VERSION
  spec.authors = ["Supabase"]
  spec.email = ["support@supabase.io"]

  spec.summary = "Ruby client for the Supabase PostgREST API"
  spec.description = "A Ruby gem implementing a query builder and HTTP client for " \
                     "the PostgREST API, mirroring supabase-py's postgrest sub-library."
  spec.homepage = "https://github.com/supabase-rb/client"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/supabase-rb/client"
  spec.metadata["documentation_uri"] = "https://github.com/supabase-rb/client/blob/master/lib/supabase/postgrest/README.md"
  spec.metadata["changelog_uri"] = "https://github.com/supabase-rb/client/blob/master/CHANGELOG.md"

  spec.files = Dir["lib/supabase/postgrest.rb", "lib/supabase/postgrest/**/*.rb",
                   "lib/supabase/postgrest/README.md", "LICENSE"]
  spec.require_paths = ["lib"]

  spec.add_dependency "faraday", "~> 2.0"

  spec.add_development_dependency "rspec", "~> 3.12"
  spec.add_development_dependency "simplecov", "~> 0.22"
  spec.add_development_dependency "webmock", "~> 3.19"

  # Async variant (lib/supabase/postgrest/async/). Not loaded by the default
  # require "supabase/postgrest" — sync-only users pay zero cost.
  spec.add_development_dependency "async", "~> 2.0"
  spec.add_development_dependency "async-http-faraday", "~> 0.20"
end
