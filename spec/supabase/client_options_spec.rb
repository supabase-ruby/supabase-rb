# frozen_string_literal: true

require "supabase"

RSpec.describe Supabase::ClientOptions do
  describe "#initialize" do
    it "fills in supabase-py-compatible defaults" do
      opts = described_class.new
      expect(opts.schema).to             eq("public")
      expect(opts.auto_refresh_token).to be true
      expect(opts.persist_session).to    be true
      expect(opts.flow_type).to          eq("pkce")
      expect(opts.postgrest_client_timeout).to eq(120)
      expect(opts.storage_client_timeout).to   eq(20)
      expect(opts.function_client_timeout).to  eq(60)
    end

    it "stamps the X-Client-Info header automatically" do
      opts = described_class.new
      expect(opts.headers["X-Client-Info"]).to match(%r{supabase-rb/})
    end

    it "merges user headers on top of the X-Client-Info default" do
      opts = described_class.new(headers: { "X-Tenant" => "acme" })
      expect(opts.headers["X-Tenant"]).to eq("acme")
      expect(opts.headers).to have_key("X-Client-Info")
    end
  end

  describe "#replace" do
    it "returns a NEW instance with overrides applied, leaving the original untouched" do
      original = described_class.new(schema: "public")
      derived  = original.replace(schema: "private", auto_refresh_token: false)

      expect(derived).not_to equal(original)
      expect(derived.schema).to             eq("private")
      expect(derived.auto_refresh_token).to be false
      # untouched fields carry over
      expect(derived.flow_type).to eq("pkce")
      # original is unchanged
      expect(original.schema).to eq("public")
    end
  end

  describe "#to_h" do
    it "round-trips through .new(**to_h)" do
      a = described_class.new(schema: "ledger")
      b = described_class.new(**a.to_h)
      expect(b.schema).to eq("ledger")
      expect(b.headers).to eq(a.headers)
    end
  end
end

RSpec.describe Supabase do
  describe ".create_client / .acreate_client / .create_async_client" do
    let(:url) { "https://abc.supabase.co" }
    let(:key) { "anon" }

    it "create_client builds a sync client" do
      c = described_class.create_client(supabase_url: url, supabase_key: key)
      expect(c.async?).to be false
    end

    it "acreate_client builds an async client (mirrors supabase-py acreate_client)" do
      c = described_class.acreate_client(supabase_url: url, supabase_key: key)
      expect(c.async?).to be true
    end

    it "create_async_client is an alias of acreate_client" do
      expect(described_class.method(:create_async_client)).to eq(described_class.method(:acreate_client))
    end

    it "accepts a Supabase::ClientOptions instance and threads its headers into the umbrella headers" do
      opts = Supabase::ClientOptions.new(headers: { "X-Tenant" => "acme" })
      c = described_class.create_client(supabase_url: url, supabase_key: key, options: opts)
      expect(c.headers["X-Tenant"]).to eq("acme")
      expect(c.headers["apikey"]).to   eq(key)
    end
  end

  describe "error re-exports" do
    # These mirror supabase-py's top-level `__init__.py` aliasing so callers can
    # write `rescue Supabase::StorageException` without reaching into sub-namespaces.
    it "re-exports the major sub-library error classes" do
      expect(Supabase::StorageException).to       eq(Supabase::Storage::Errors::StorageError)
      expect(Supabase::StorageApiError).to        eq(Supabase::Storage::Errors::StorageApiError)
    end

    it "defines Supabase::SupabaseException for url/key validation errors" do
      expect(Supabase::SupabaseException.ancestors).to include(StandardError)
    end
  end
end
