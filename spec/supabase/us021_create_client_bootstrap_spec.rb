# frozen_string_literal: true

require "supabase"
require "webmock/rspec"
require "json"

# US-021 — `Supabase.create_client` makes the bootstrap call (F-C6).
#
# The public factory must restore any persisted session out of the auth
# storage at construction time and apply its access_token as the bearer used
# by postgrest/storage/functions. Prior to this change, `create_client` went
# through `Client.new`, which only stamps `Bearer <anon_key>` — meaning the
# very first postgrest request after `create_client` would silently bypass RLS
# rules that depend on `auth.uid()`.
RSpec.describe "Supabase.create_client bootstrap (US-021 / F-C6)" do
  let(:project_url) { "https://abc.supabase.co" }
  let(:anon_key)    { "anon-key" }
  let(:user_jwt)    { "user-jwt-from-storage" }

  # Pre-populate a storage with the same on-disk shape Auth::Client writes via
  # `_save_session` so that `get_session` on the new client recovers a Session
  # struct with `access_token == user_jwt`.
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

  describe ".create_client" do
    it "restores the persisted session and uses its access_token as the bearer" do
      WebMock.disable_net_connect!

      client = Supabase.create_client(
        supabase_url: project_url,
        supabase_key: anon_key,
        options: { auth: { storage: persisted_storage } }
      )

      # 1. Auth client sees the persisted session.
      session = client.auth.get_session
      expect(session).not_to be_nil
      expect(session.access_token).to eq(user_jwt)

      # 2. Downstream sub-clients use the user JWT, not the anon key.
      stub = stub_request(:get, %r{#{Regexp.escape(project_url)}/rest/v1/users(\?.*)?})
             .with(headers: { "apikey" => anon_key, "Authorization" => "Bearer #{user_jwt}" })
             .to_return(status: 200, body: JSON.generate([{ "id" => 1 }]))

      client.from("users").select("*").execute

      expect(stub).to have_been_requested
    ensure
      WebMock.allow_net_connect!
    end

    it "falls back to the anon-key bearer when no session is persisted" do
      empty_storage = Supabase::Auth::MemoryStorage.new

      client = Supabase.create_client(
        supabase_url: project_url,
        supabase_key: anon_key,
        options: { auth: { storage: empty_storage } }
      )

      expect(client.headers["Authorization"]).to eq("Bearer #{anon_key}")
      expect(client.auth.get_session).to be_nil
    end

    it "honors an explicit Authorization in options[:global][:headers] over the persisted session" do
      client = Supabase.create_client(
        supabase_url: project_url,
        supabase_key: anon_key,
        options: {
          auth:   { storage: persisted_storage },
          global: { headers: { "Authorization" => "Bearer explicit-override" } }
        }
      )

      expect(client.headers["Authorization"]).to eq("Bearer explicit-override")
    end
  end

  describe ".acreate_client" do
    it "also routes through Client.create so async clients bootstrap too" do
      client = Supabase.acreate_client(
        supabase_url: project_url,
        supabase_key: anon_key,
        options: { auth: { storage: persisted_storage } }
      )

      expect(client.async?).to be true
      expect(client.headers["Authorization"]).to eq("Bearer #{user_jwt}")
    end
  end
end
