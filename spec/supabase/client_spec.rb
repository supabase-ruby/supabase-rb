# frozen_string_literal: true

require "supabase"
require "webmock/rspec"
require "json"

RSpec.describe Supabase::Client do
  let(:project_url) { "https://abc.supabase.co" }
  let(:key)         { "anon-key" }
  let(:client)      { described_class.new(supabase_url: project_url, supabase_key: key) }

  # ---------------------------------------------------------------------------
  # Constructor + factory
  # ---------------------------------------------------------------------------

  describe ".create_client (the public factory)" do
    it "is a thin wrapper that builds a Supabase::Client" do
      c = Supabase.create_client(supabase_url: project_url, supabase_key: key)
      expect(c).to be_a(described_class)
    end
  end

  describe "#initialize" do
    it "requires both URL and key" do
      expect { described_class.new(supabase_url: "", supabase_key: key) }
        .to raise_error(Supabase::SupabaseException, /supabase_url/)
      expect { described_class.new(supabase_url: project_url, supabase_key: "") }
        .to raise_error(Supabase::SupabaseException, /supabase_key/)
    end

    it "rejects URLs without an http(s) scheme (mirrors supabase-py's Invalid URL check)" do
      expect { described_class.new(supabase_url: "not-a-url", supabase_key: key) }
        .to raise_error(Supabase::SupabaseException, /Invalid URL/)
    end

    it "strips a trailing slash from the project URL" do
      c = described_class.new(supabase_url: "#{project_url}/", supabase_key: key)
      expect(c.supabase_url).to eq(project_url)
    end

    it "stamps apikey + Authorization headers using the same key by default" do
      expect(client.headers).to include(
        "apikey"        => key,
        "Authorization" => "Bearer #{key}"
      )
    end

    it "merges global custom headers from options[:global][:headers]" do
      c = described_class.new(
        supabase_url: project_url, supabase_key: key,
        options: { global: { headers: { "X-Custom" => "value" } } }
      )
      expect(c.headers["X-Custom"]).to eq("value")
    end

    it "tracks the async flag via #async?" do
      expect(client.async?).to be false
      expect(described_class.new(supabase_url: project_url, supabase_key: key, async: true).async?).to be true
    end
  end

  # ---------------------------------------------------------------------------
  # Sub-client URLs derived from the project URL
  # ---------------------------------------------------------------------------

  describe "URL derivation" do
    it "anchors auth at /auth/v1" do
      expect(client.auth.url).to eq("#{project_url}/auth/v1")
    end

    it "anchors postgrest at /rest/v1" do
      expect(client.postgrest.base_url).to eq("#{project_url}/rest/v1")
    end

    it "anchors storage at /storage/v1/ (trailing slash so URL joining is clean)" do
      expect(client.storage.base_url).to eq("#{project_url}/storage/v1/")
    end

    it "anchors functions at /functions/v1" do
      expect(client.functions.base_url).to eq("#{project_url}/functions/v1")
    end

    it "upgrades https to wss for realtime and routes through /realtime/v1/websocket" do
      url = client.realtime.url
      expect(url).to start_with("wss://abc.supabase.co/realtime/v1/websocket")
      expect(url).to include("apikey=anon-key")
    end

    it "downgrades to ws:// when the project URL is http://" do
      c = described_class.new(supabase_url: "http://localhost:54321", supabase_key: key)
      expect(c.realtime.url).to start_with("ws://localhost:54321/realtime/v1/websocket")
    end
  end

  # ---------------------------------------------------------------------------
  # Sub-client memoization + sync vs async classes
  # ---------------------------------------------------------------------------

  describe "sub-client memoization" do
    it "returns the same instance on repeated calls" do
      a = client.auth
      b = client.auth
      expect(a).to be(b)
      expect(client.postgrest).to be(client.postgrest)
      expect(client.storage).to be(client.storage)
      expect(client.functions).to be(client.functions)
      expect(client.realtime).to be(client.realtime)
    end
  end

  describe "async: true" do
    let(:async_client) { described_class.new(supabase_url: project_url, supabase_key: key, async: true) }

    it "swaps auth/postgrest/storage/functions to their Async variants" do
      expect(async_client.auth).to      be_a(Supabase::Auth::Async::Client)
      expect(async_client.postgrest).to be_a(Supabase::Postgrest::Async::Client)
      expect(async_client.storage).to   be_a(Supabase::Storage::Async::Client)
      expect(async_client.functions).to be_a(Supabase::Functions::Async::Client)
    end

    it "keeps realtime sync (no async transport ships; user attaches their own)" do
      expect(async_client.realtime).to be_a(Supabase::Realtime::Client)
    end
  end

  # ---------------------------------------------------------------------------
  # Postgrest shortcuts (.from / .rpc / .schema)
  # ---------------------------------------------------------------------------

  describe "Postgrest shortcuts on the umbrella" do
    it "#from(table) delegates to postgrest.from" do
      builder = client.from("users").select("*")
      expect(builder.request.path).to eq("/rest/v1/users")
    end

    it "#rpc(name, params) delegates to postgrest.rpc" do
      rpc = client.rpc("inc_by", { x: 1 })
      expect(rpc.request.http_method).to eq("POST")
      expect(rpc.request.path).to eq("/rest/v1/rpc/inc_by")
    end

    it "#schema('private') swaps the postgrest client to a private-schema one and chains" do
      result = client.schema("private")
      expect(result).to be(client)
      expect(client.postgrest.schema_name).to eq("private")
    end
  end

  # ---------------------------------------------------------------------------
  # set_auth — shared bearer token across sub-clients
  # ---------------------------------------------------------------------------

  describe "#set_auth" do
    it "replaces the Authorization header with the new user JWT" do
      client.set_auth("user-jwt-123")
      expect(client.headers["Authorization"]).to eq("Bearer user-jwt-123")
    end

    it "resets the memoized HTTP sub-clients so they pick up the new header" do
      first_auth = client.auth
      client.set_auth("user-jwt")
      expect(client.auth).not_to be(first_auth)
    end

    it "falls back to the original anon key when set_auth(nil) is called (sign-out)" do
      client.set_auth("user-jwt")
      client.set_auth(nil)
      expect(client.headers["Authorization"]).to eq("Bearer #{key}")
    end
  end

  # ---------------------------------------------------------------------------
  # End-to-end smoke: one HTTP roundtrip per sub-library
  # ---------------------------------------------------------------------------

  describe "end-to-end smoke (one request per sub-library)" do
    before { WebMock.disable_net_connect! }
    after  { WebMock.allow_net_connect! }

    it "postgrest: client.from('users').select('*').execute" do
      stub_request(:get, %r{#{Regexp.escape(project_url)}/rest/v1/users(\?.*)?})
        .with(headers: { "apikey" => key, "Authorization" => "Bearer #{key}" })
        .to_return(status: 200, body: JSON.generate([{ "id" => 1 }]))

      resp = client.from("users").select("*").execute
      expect(resp.data).to eq([{ "id" => 1 }])
    end

    it "storage: client.storage.list_buckets" do
      stub_request(:get, "#{project_url}/storage/v1/bucket")
        .to_return(status: 200, body: JSON.generate([{ "id" => "avatars", "name" => "avatars", "public" => true }]))

      buckets = client.storage.list_buckets
      expect(buckets.first.id).to eq("avatars")
    end

    it "functions: client.functions.invoke('hello')" do
      stub_request(:post, "#{project_url}/functions/v1/hello")
        .with(body: JSON.generate("name" => "Ada"))
        .to_return(status: 200, body: JSON.generate("greeting" => "hi Ada"),
                   headers: { "Content-Type" => "application/json" })

      r = client.functions.invoke("hello", body: { name: "Ada" })
      expect(r.data).to eq("greeting" => "hi Ada")
    end
  end
end
