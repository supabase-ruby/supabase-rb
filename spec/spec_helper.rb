# frozen_string_literal: true

require "simplecov"

# Skip the global coverage threshold when the only thing being run is the
# integration smoke suite. Those specs deliberately exercise a small slice of
# `lib/` against a live Supabase stack, so the global gate would always fail
# even on a fully passing run. Full-suite runs (`bundle exec rspec`) still
# enforce the threshold.
_integration_only =
  begin
    user_args = ARGV.reject { |a| a.start_with?("-") }
    user_args.any? && user_args.all? { |a| a.include?("spec/integration") }
  end

SimpleCov.start do
  add_filter "/spec/"
  minimum_coverage 88 unless _integration_only
end

require "supabase/auth"

# Load all support files
Dir[File.join(__dir__, "support", "**", "*.rb")].reject { |f| f.end_with?("_spec.rb") }.each { |f| require f }

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
end
