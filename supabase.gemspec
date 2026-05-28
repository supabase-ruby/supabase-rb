# frozen_string_literal: true

require_relative "lib/supabase/version"

Gem::Specification.new do |spec|
  spec.name = "supabase"
  spec.version = Supabase::VERSION
  spec.authors = ["Supabase"]
  spec.email = ["support@supabase.io"]

  spec.summary = "Ruby client for Supabase (umbrella gem)"
  spec.description = "Meta-gem combining supabase-auth, supabase-postgrest, supabase-storage, " \
                     "supabase-functions, and supabase-realtime behind a single " \
                     "Supabase.create_client(supabase_url:, supabase_key:) factory, mirroring " \
                     "supabase-py's create_client()."
  spec.homepage = "https://github.com/suparails/supabase-rb"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/suparails/supabase-rb"

  spec.files = Dir["lib/supabase.rb", "lib/supabase/version.rb", "lib/supabase/client.rb",
                   "LICENSE", "README.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "supabase-auth",      "~> 0.1"
  spec.add_dependency "supabase-postgrest", "~> 0.1"
  spec.add_dependency "supabase-storage",   "~> 0.1"
  spec.add_dependency "supabase-functions", "~> 0.1"
  spec.add_dependency "supabase-realtime",  "~> 0.1"

  spec.add_development_dependency "rspec", "~> 3.12"
  spec.add_development_dependency "simplecov", "~> 0.22"
  spec.add_development_dependency "webmock", "~> 3.19"
end
