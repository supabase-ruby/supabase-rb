# frozen_string_literal: true

require "supabase"
require "webmock/rspec"
require "json"

# Regression suite for the legacy-options-shape detector in Supabase::Client.
#
# The legacy nested shape `{ auth: {...}, postgrest: {...}, global: {...} }`
# used to be detected by key presence alone, and the marker list included
# `:storage` and `:realtime` — both of which are ALSO ClientOptions fields.
# Consequences before the fix:
#
#   * `options: { schema: "private", realtime: {...} }` was mis-detected as
#     legacy → `schema` was silently dropped;
#   * `options: { storage: session_storage_object }` (py-style session
#     storage) was mis-detected as legacy → `sub_options(:storage)` called
#     `transform_keys` on the storage object → NoMethodError.
#
# Now only `:auth`/`:postgrest`/`:functions`/`:global` are unambiguous legacy
# markers; `:storage` is disambiguated by value (Hash → legacy sub-client
# kwargs, object → ClientOptions session storage) and `:realtime` alone is
# never a legacy marker (both shapes deliver the same Hash to the realtime
# client).
RSpec.describe "Supabase::Client legacy options shape detection" do
  let(:project_url) { "https://abc.supabase.co" }
  let(:anon_key)    { "anon-key" }

  def build_client(options)
    Supabase::Client.new(supabase_url: project_url, supabase_key: anon_key, options: options)
  end

  describe "ClientOptions fields colliding with legacy keys" do
    it "keeps :schema when :realtime is passed alongside it (was silently dropped)" do
      client = build_client(schema: "private", realtime: { heartbeat_interval: 17 })

      expect(client.options).to be_a(Supabase::ClientOptions)
      expect(client.options.schema).to eq("private")
      expect(client.realtime.heartbeat_interval).to eq(17)
    end

    it "routes a non-Hash :storage value to the auth client as session storage (was NoMethodError)" do
      session_storage = Supabase::Auth::MemoryStorage.new
      client = build_client(storage: session_storage)

      expect(client.options).to be_a(Supabase::ClientOptions)
      expect(client.options.storage).to be(session_storage)
      expect { client.storage }.not_to raise_error
    end
  end

  describe "legacy nested shape still works" do
    it "treats a Hash under :storage as legacy storage sub-client kwargs" do
      client = build_client(storage: { timeout: 33 })

      expect(client.options).to be_a(Hash)
      expect(client.storage.instance_variable_get(:@timeout)).to eq(33)
    end

    it "treats any unambiguous legacy key (:auth/:postgrest/:functions/:global) as legacy" do
      client = build_client(global: { headers: { "X-Custom" => "v" } })

      expect(client.options).to be_a(Hash)
      expect(client.headers["X-Custom"]).to eq("v")
    end

    it "warns when flat ClientOptions fields are mixed into the legacy shape (they are ignored)" do
      expect do
        build_client(schema: "private", auth: { auto_refresh_token: false })
      end.to output(/options \[:schema\] are ignored/).to_stderr
    end

    it "does not warn for a pure legacy hash" do
      expect do
        build_client(auth: { auto_refresh_token: false }, global: { headers: {} })
      end.not_to output.to_stderr
    end
  end

  describe "Client.create with a flat ClientOptions-style hash" do
    let(:user_jwt) { "user-jwt-from-storage" }

    let(:persisted_storage) do
      serialized = {
        "access_token"  => user_jwt,
        "refresh_token" => "refresh-from-storage",
        "token_type"    => "bearer",
        "expires_in"    => 3600,
        "expires_at"    => Time.now.to_i + 3600,
        "user"          => { "id" => "user-from-storage" }
      }
      storage = Supabase::Auth::MemoryStorage.new
      storage.set_item(Supabase::Auth::Client::STORAGE_KEY, JSON.generate(serialized))
      storage
    end

    it "honors an explicit Authorization in flat options[:headers] over the persisted session" do
      client = Supabase.create_client(
        supabase_url: project_url,
        supabase_key: anon_key,
        options: {
          headers: { "Authorization" => "Bearer explicit-override" },
          storage: persisted_storage
        }
      )

      expect(client.headers["Authorization"]).to eq("Bearer explicit-override")
    end

    it "still bootstraps from a persisted session passed via flat :storage" do
      client = Supabase.create_client(
        supabase_url: project_url,
        supabase_key: anon_key,
        options: { storage: persisted_storage }
      )

      expect(client.headers["Authorization"]).to eq("Bearer #{user_jwt}")
    end
  end
end
