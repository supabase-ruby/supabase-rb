# frozen_string_literal: true

require "supabase/postgrest"

RSpec.describe Supabase::Postgrest::Client do
  describe "#initialize" do
    it "sets the default JSON headers and the Accept-/Content-Profile pair" do
      client = described_class.new(base_url: "https://example.com/rest/v1")

      expect(client.headers).to include(
        "Accept"          => "application/json",
        "Content-Type"    => "application/json",
        "Accept-Profile"  => "public",
        "Content-Profile" => "public"
      )
      expect(client.headers["X-Client-Info"]).to match(/supabase-rb\/postgrest-rb v/)
    end

    it "uses the schema provided for both profile headers" do
      client = described_class.new(base_url: "https://example.com/rest/v1", schema: "private")
      expect(client.headers["Accept-Profile"]).to eq("private")
      expect(client.headers["Content-Profile"]).to eq("private")
      expect(client.schema_name).to eq("private")
    end

    it "merges user-supplied headers over the defaults" do
      client = described_class.new(
        base_url: "https://example.com/rest/v1",
        headers:  { "apikey" => "k", "Accept" => "text/csv" }
      )

      expect(client.headers["apikey"]).to eq("k")
      expect(client.headers["Accept"]).to eq("text/csv")
    end

    it "strips a trailing slash from the base URL" do
      client = described_class.new(base_url: "https://example.com/rest/v1/")
      expect(client.base_url).to eq("https://example.com/rest/v1")
    end
  end

  describe "DEFAULT_POSTGREST_TIMEOUT (US-032)" do
    it "exposes the 120s default as a constant" do
      expect(Supabase::Postgrest::DEFAULT_POSTGREST_TIMEOUT).to eq(120)
    end

    it "applies the default timeout to the Faraday session when timeout: is omitted" do
      client = described_class.new(base_url: "https://example.com/rest/v1")
      session = client.send(:session)
      expect(session.options.timeout).to eq(120)
      expect(session.options.open_timeout).to eq(120)
    end

    it "applies the default timeout when timeout: nil is passed explicitly" do
      client = described_class.new(base_url: "https://example.com/rest/v1", timeout: nil)
      session = client.send(:session)
      expect(session.options.timeout).to eq(120)
    end

    it "honors an explicit numeric timeout over the default" do
      client = described_class.new(base_url: "https://example.com/rest/v1", timeout: 7)
      session = client.send(:session)
      expect(session.options.timeout).to eq(7)
    end
  end

  describe "#schema" do
    it "returns a new client pointed at a different postgres schema" do
      original = described_class.new(base_url: "https://example.com/rest/v1", schema: "public")
      switched = original.schema("private")

      expect(switched).not_to be(original)
      expect(switched.schema_name).to eq("private")
      expect(switched.headers["Accept-Profile"]).to eq("private")
      expect(switched.headers["Content-Profile"]).to eq("private")
      expect(original.schema_name).to eq("public")
    end

    it "preserves user-supplied non-profile headers across the switch" do
      original = described_class.new(
        base_url: "https://example.com/rest/v1",
        headers:  { "apikey" => "k" }
      )
      switched = original.schema("other")
      expect(switched.headers["apikey"]).to eq("k")
    end
  end

  describe "#from / #table" do
    let(:client) { described_class.new(base_url: "https://example.com/rest/v1") }

    it "produces a RequestBuilder rooted at /rest/v1/<table>" do
      builder = client.from("users").select("id")
      expect(builder.request.path).to eq("/rest/v1/users")
    end

    it "exposes #table as an alias of #from" do
      expect(client.method(:table)).to eq(client.method(:from))
    end
  end

  describe "#rpc" do
    let(:client) { described_class.new(base_url: "https://example.com/rest/v1") }

    it "defaults to POST with the params as the JSON body" do
      rpc = client.rpc("create_thing", { name: "x" })
      expect(rpc.request.http_method).to eq("POST")
      expect(rpc.request.path).to eq("/rest/v1/rpc/create_thing")
      expect(rpc.request.json).to eq(name: "x")
      expect(rpc.request.params).to be_empty
    end

    it "sends args as the query string when get: true" do
      rpc = client.rpc("get_thing", { id: 1 }, get: true)
      expect(rpc.request.http_method).to eq("GET")
      expect(rpc.request.json).to be_nil
      expect(rpc.request.params).to eq("id" => 1)
    end

    it "switches to HEAD when head: true" do
      rpc = client.rpc("count_things", {}, head: true)
      expect(rpc.request.http_method).to eq("HEAD")
    end

    it "adds the Prefer count header when count: is supplied" do
      rpc = client.rpc("fn", {}, count: "exact")
      expect(rpc.request.headers["Prefer"]).to eq("count=exact")
    end

    describe "client-level Prefer wins over per-call (US-033)" do
      it "client headers override the per-call Prefer set by count:" do
        client_with_prefer = described_class.new(
          base_url: "https://example.com/rest/v1",
          headers: { "Prefer" => "tx=rollback" }
        )
        rpc = client_with_prefer.rpc("fn", {}, count: "exact")
        expect(rpc.request.headers["Prefer"]).to eq("tx=rollback")
      end
    end
  end
end
