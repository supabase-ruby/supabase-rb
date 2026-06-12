# frozen_string_literal: true

require "supabase"
require "supabase/realtime"

# C-TL-3 (docs/PARITY.md): the umbrella builds its realtime client lazily. If a
# caller signs in (or set_auth is called) BEFORE realtime is first accessed,
# apply_auth cannot push the token to a not-yet-built realtime client. The lazy
# accessor must therefore seed the join auth from the current access token, not
# the anon key — otherwise channels opened after sign-in authorize with the anon
# key and RLS never sees the user (same failure class as realtime D1).
RSpec.describe "Supabase::Client lazy realtime picks up the session token" do
  let(:project_url) { "https://abc.supabase.co" }
  let(:key)         { "anon-key" }
  let(:client)      { Supabase::Client.new(supabase_url: project_url, supabase_key: key) }

  it "seeds realtime access_token from a set_auth that happened before first access" do
    # set_auth runs while @realtime is still nil (lazy).
    client.set_auth("user-session-jwt")

    # First access builds realtime — it must use the rotated token, not the key.
    expect(client.realtime.access_token).to eq("user-session-jwt")
    # apikey stays the anon key (it identifies the project, not the user).
    expect(client.realtime.params["apikey"]).to eq(key)
  end

  it "uses the anon key when no sign-in / set_auth happened" do
    expect(client.realtime.access_token).to eq(key)
  end

  it "still propagates a later set_auth to the already-built realtime client" do
    rt = client.realtime # build first
    expect(rt.access_token).to eq(key)

    client.set_auth("rotated-jwt")
    expect(client.realtime.access_token).to eq("rotated-jwt")
  end

  it "clears the live realtime token on sign-out (token nil), matching py set_auth(None)" do
    client.set_auth("user-session-jwt")
    expect(client.realtime.access_token).to eq("user-session-jwt")

    # On an already-built realtime, set_auth(nil) propagates nil — subsequent
    # joins omit access_token (D1) and fall back to the apikey in the URL.
    client.set_auth(nil)
    expect(client.realtime.access_token).to be_nil
  end

  it "seeds a lazily-built realtime with the anon key after a sign-out (token nil)" do
    # No realtime built yet; sign-out leaves the umbrella's seed token as anon.
    client.set_auth(nil)
    expect(client.realtime.access_token).to eq(key)
  end
end
