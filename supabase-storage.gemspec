# frozen_string_literal: true

require_relative "lib/supabase/storage/version"

Gem::Specification.new do |spec|
  spec.name = "supabase-storage"
  spec.version = Supabase::Storage::VERSION
  spec.authors = ["Supabase"]
  spec.email = ["support@supabase.io"]

  spec.summary = "Ruby client for the Supabase Storage API"
  spec.description = "A Ruby gem for the Supabase Storage REST API — bucket management, " \
                     "file upload/download, and signed URLs. Mirrors supabase-py's storage3."
  spec.homepage = "https://github.com/supabase-rb/client"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/supabase-rb/client"
  spec.metadata["documentation_uri"] = "https://github.com/supabase-rb/client/blob/master/lib/supabase/storage/README.md"
  spec.metadata["changelog_uri"] = "https://github.com/supabase-rb/client/blob/master/CHANGELOG.md"

  spec.files = Dir["lib/supabase/storage.rb", "lib/supabase/storage/**/*.rb",
                   "lib/supabase/storage/README.md", "LICENSE"]
  spec.require_paths = ["lib"]

  spec.add_dependency "faraday", "~> 2.0"
  spec.add_dependency "faraday-multipart", "~> 1.0"

  spec.add_development_dependency "rspec", "~> 3.12"
  spec.add_development_dependency "simplecov", "~> 0.22"
  spec.add_development_dependency "webmock", "~> 3.19"

  # Async variant (lib/supabase/storage/async/). Not loaded by the default
  # require "supabase/storage" — sync-only users pay zero cost.
  spec.add_development_dependency "async", "~> 2.0"
  spec.add_development_dependency "async-http-faraday", "~> 0.20"
end
