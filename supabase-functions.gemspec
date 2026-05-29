# frozen_string_literal: true

require_relative "lib/supabase/functions/version"

Gem::Specification.new do |spec|
  spec.name = "supabase-functions"
  spec.version = Supabase::Functions::VERSION
  spec.authors = ["Supabase"]
  spec.email = ["support@supabase.io"]

  spec.summary = "Ruby client for invoking Supabase Edge Functions"
  spec.description = "A Ruby gem for invoking Supabase Edge Functions via HTTP. " \
                     "Mirrors supabase-py's supabase_functions sub-library."
  spec.homepage = "https://github.com/supabase-rb/client"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/supabase-rb/client"
  spec.metadata["documentation_uri"] = "https://github.com/supabase-rb/client/blob/master/lib/supabase/functions/README.md"
  spec.metadata["changelog_uri"] = "https://github.com/supabase-rb/client/blob/master/CHANGELOG.md"

  spec.files = Dir["lib/supabase/functions.rb", "lib/supabase/functions/**/*.rb",
                   "lib/supabase/functions/README.md", "LICENSE"]
  spec.require_paths = ["lib"]

  spec.add_dependency "faraday", "~> 2.0"

  spec.add_development_dependency "rspec", "~> 3.12"
  spec.add_development_dependency "simplecov", "~> 0.22"
  spec.add_development_dependency "webmock", "~> 3.19"

  # Async variant (lib/supabase/functions/async/). Not loaded by the default
  # require "supabase/functions" — sync-only users pay zero cost.
  spec.add_development_dependency "async", "~> 2.0"
  spec.add_development_dependency "async-http-faraday", "~> 0.20"
end
