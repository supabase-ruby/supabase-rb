# frozen_string_literal: true

RSpec.describe "require 'supabase/auth'" do
  it "loads the gem without errors" do
    expect(defined?(Supabase::Auth)).to be_truthy
    expect(defined?(Supabase::Auth::Client)).to be_truthy
    expect(defined?(Supabase::Auth::VERSION)).to be_truthy
  end
end
