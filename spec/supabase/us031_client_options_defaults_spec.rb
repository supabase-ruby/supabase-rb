# frozen_string_literal: true

require "supabase"
require "faraday"

# US-031 / F-C12 — ClientOptions defaults aligned with supabase-py.
#
# Two contracts pinned here:
# 1. `Client.new(url, key, options: {})` ends up with the py-aligned defaults:
#    auth.flow_type == "pkce", postgrest timeout == 120, storage == 20,
#    functions == 5 (the latter dropped from 60 in this story).
# 2. A custom `http_client` (Faraday::Connection) threaded through `options:`
#    reaches every sub-client — auth, postgrest, storage, functions — so a
#    single shared connection (or a Faraday test adapter) wires the entire
#    umbrella.
RSpec.describe Supabase::Client, "US-031 — ClientOptions defaults aligned with py" do
  let(:project_url) { "https://abc.supabase.co" }
  let(:key)         { "anon-key" }

  describe "with options: {} (the empty-hash → ClientOptions path)" do
    let(:client) { described_class.new(supabase_url: project_url, supabase_key: key, options: {}) }

    it "auth.flow_type defaults to 'pkce' (paritet with supabase-py, not the Auth::Client native 'implicit' default)" do
      # auth.flow_type publicly exposed via the _flow_type test accessor.
      expect(client.auth._flow_type).to eq("pkce")
    end

    it "postgrest timeout defaults to 120" do
      expect(client.postgrest.instance_variable_get(:@timeout)).to eq(120)
    end

    it "storage timeout defaults to 20" do
      expect(client.storage.instance_variable_get(:@timeout)).to eq(20)
    end

    it "functions timeout defaults to 5 (was 60 — BREAKING in this story)" do
      expect(client.functions.instance_variable_get(:@timeout)).to eq(5)
    end

    it "DEFAULT_FUNCTIONS_TIMEOUT constant is 5 (pin AC #1)" do
      expect(Supabase::ClientOptions::DEFAULT_FUNCTIONS_TIMEOUT).to eq(5)
    end
  end

  describe "Hash options → ClientOptions conversion (AC #2)" do
    it "a plain {} Hash is converted into a ClientOptions struct" do
      c = described_class.new(supabase_url: project_url, supabase_key: key, options: {})
      expect(c.options).to be_a(Supabase::ClientOptions)
    end

    it "Hash kwargs are forwarded through to the struct (schema: 'private')" do
      c = described_class.new(supabase_url: project_url, supabase_key: key,
                              options: { schema: "private" })
      expect(c.options).to be_a(Supabase::ClientOptions)
      expect(c.options.schema).to eq("private")
    end

    it "an existing ClientOptions instance is isolated (shallow dup) but field values survive" do
      # US-043 changed the contract from "pass-through (identity)" to "shallow
      # dup" so callers reusing one ClientOptions across multiple clients can't
      # bleed header mutations between them. Field values still round-trip.
      opts = Supabase::ClientOptions.new(schema: "ledger")
      c = described_class.new(supabase_url: project_url, supabase_key: key, options: opts)
      expect(c.options).not_to be(opts)
      expect(c.options).to be_a(Supabase::ClientOptions)
      expect(c.options.schema).to eq("ledger")
    end
  end

  describe "custom http_client in options reaches every sub-client (AC #5)" do
    let(:custom_faraday) do
      Faraday.new(url: project_url) do |f|
        f.adapter :test do |stub|
          stub.get("/whatever") { [200, {}, ""] }
        end
      end
    end

    it "via ClientOptions: http_client is plumbed into auth/postgrest/storage/functions" do
      opts = Supabase::ClientOptions.new(http_client: custom_faraday)
      c = described_class.new(supabase_url: project_url, supabase_key: key, options: opts)

      expect(c.auth.instance_variable_get(:@http_client)).to      be(custom_faraday)
      expect(c.postgrest.instance_variable_get(:@http_client)).to be(custom_faraday)
      # Storage / Functions assign the injected connection to @session (they
      # use it directly as the Faraday client, not just as a stored handle).
      expect(c.storage.instance_variable_get(:@session)).to       be(custom_faraday)
      expect(c.functions.instance_variable_get(:@session)).to     be(custom_faraday)
    end

    it "via Hash: http_client: in options Hash gets converted into ClientOptions and threaded down" do
      c = described_class.new(supabase_url: project_url, supabase_key: key,
                              options: { http_client: custom_faraday })

      expect(c.options).to be_a(Supabase::ClientOptions)
      expect(c.auth.instance_variable_get(:@http_client)).to      be(custom_faraday)
      expect(c.postgrest.instance_variable_get(:@http_client)).to be(custom_faraday)
      expect(c.storage.instance_variable_get(:@session)).to       be(custom_faraday)
      expect(c.functions.instance_variable_get(:@session)).to     be(custom_faraday)
    end
  end
end
