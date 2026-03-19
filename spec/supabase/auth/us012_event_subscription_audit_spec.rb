# frozen_string_literal: true

require "spec_helper"
require "json"
require "faraday"

RSpec.describe "US-012: Audit Event Subscription System" do
  let(:base_url) { "http://localhost:9999" }
  let(:default_headers) { { "apikey" => "test-key" } }

  let(:mock_user) do
    {
      "id" => "user-123",
      "aud" => "authenticated",
      "role" => "authenticated",
      "email" => "test@example.com",
      "phone" => "+1234567890",
      "created_at" => "2024-01-01T00:00:00Z",
      "updated_at" => "2024-01-01T00:00:00Z",
      "app_metadata" => {},
      "user_metadata" => {}
    }
  end

  let(:mock_session) do
    {
      "access_token" => "test-access-token",
      "refresh_token" => "test-refresh-token",
      "token_type" => "bearer",
      "expires_in" => 3600,
      "expires_at" => Time.now.to_i + 3600,
      "user" => mock_user
    }
  end

  let(:mock_storage) do
    store = {}
    storage = Object.new
    storage.define_singleton_method(:get_item) { |key| store[key] }
    storage.define_singleton_method(:set_item) { |key, value| store[key] = value }
    storage.define_singleton_method(:remove_item) { |key| store.delete(key) }
    storage.define_singleton_method(:store) { store }
    storage
  end

  def build_client_with_stubs(persist_session: false, storage: nil, &block)
    stubs = Faraday::Adapter::Test::Stubs.new(&block)
    conn = Faraday.new(url: base_url) do |f|
      f.response :raise_error
      f.adapter :test, stubs
    end
    opts = {
      url: base_url,
      headers: default_headers,
      auto_refresh_token: false,
      persist_session: persist_session,
      detect_session_in_url: false,
      http_client: conn
    }
    opts[:storage] = storage if storage
    client = Supabase::Auth::Client.new(**opts)
    [client, stubs]
  end

  # ─── AC-1: on_auth_state_change returns Subscription with unsubscribe ───

  describe "on_auth_state_change" do
    it "returns a Subscription with id, callback, and unsubscribe" do
      client, _stubs = build_client_with_stubs
      subscription = client.on_auth_state_change { |_event, _session| }

      expect(subscription).to be_a(Supabase::Auth::Types::Subscription)
      expect(subscription.id).to be_a(String)
      expect(subscription.id).to match(/\A[0-9a-f-]{36}\z/)
      expect(subscription.callback).to be_a(Proc)
      expect(subscription.unsubscribe).to be_a(Proc)
    end

    it "generates unique IDs for each subscription" do
      client, _stubs = build_client_with_stubs
      sub1 = client.on_auth_state_change { |_e, _s| }
      sub2 = client.on_auth_state_change { |_e, _s| }

      expect(sub1.id).not_to eq(sub2.id)
    end

    it "matches Python: uses UUID string as subscription ID" do
      client, _stubs = build_client_with_stubs
      subscription = client.on_auth_state_change { |_e, _s| }

      # Python uses str(uuid4()), Ruby uses SecureRandom.uuid — both produce UUID format
      expect(subscription.id).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/)
    end

    it "stores subscription in _state_change_emitters" do
      client, _stubs = build_client_with_stubs
      subscription = client.on_auth_state_change { |_e, _s| }

      emitters = client.instance_variable_get(:@state_change_emitters)
      expect(emitters[subscription.id]).to eq(subscription)
    end
  end

  # ─── AC-2: All auth events emitted correctly ───

  describe "SIGNED_IN event" do
    it "emitted on sign_up when session returned" do
      events = []
      client, _stubs = build_client_with_stubs do |stub|
        stub.post("/signup") { [200, {}, JSON.generate(mock_session)] }
      end
      client.on_auth_state_change { |event, session| events << [event, session] }

      client.sign_up(email: "test@example.com", password: "password123")

      expect(events.length).to eq(1)
      expect(events[0][0]).to eq("SIGNED_IN")
      expect(events[0][1]).to be_a(Supabase::Auth::Types::Session)
    end

    it "emitted on sign_in_with_password" do
      events = []
      client, _stubs = build_client_with_stubs do |stub|
        stub.post("/token") { [200, {}, JSON.generate(mock_session)] }
      end
      client.on_auth_state_change { |event, session| events << [event, session] }

      client.sign_in_with_password(email: "test@example.com", password: "password123")

      expect(events.length).to eq(1)
      expect(events[0][0]).to eq("SIGNED_IN")
      expect(events[0][1]).to be_a(Supabase::Auth::Types::Session)
    end

    it "emitted on sign_in_anonymously" do
      events = []
      client, _stubs = build_client_with_stubs do |stub|
        stub.post("/signup") { [200, {}, JSON.generate(mock_session)] }
      end
      client.on_auth_state_change { |event, session| events << [event, session] }

      client.sign_in_anonymously

      expect(events.length).to eq(1)
      expect(events[0][0]).to eq("SIGNED_IN")
    end

    it "emitted on sign_in_with_id_token" do
      events = []
      client, _stubs = build_client_with_stubs do |stub|
        stub.post("/token") { [200, {}, JSON.generate(mock_session)] }
      end
      client.on_auth_state_change { |event, session| events << [event, session] }

      client.sign_in_with_id_token(provider: "google", token: "id-token-123")

      expect(events.length).to eq(1)
      expect(events[0][0]).to eq("SIGNED_IN")
    end

    it "emitted on verify_otp with session" do
      events = []
      client, _stubs = build_client_with_stubs do |stub|
        stub.post("/verify") { [200, {}, JSON.generate(mock_session)] }
      end
      client.on_auth_state_change { |event, session| events << [event, session] }

      client.verify_otp(email: "test@example.com", token: "123456", type: "email")

      expect(events.length).to eq(1)
      expect(events[0][0]).to eq("SIGNED_IN")
    end
  end

  describe "SIGNED_OUT event" do
    it "emitted on sign_out" do
      events = []
      client, _stubs = build_client_with_stubs(persist_session: true, storage: mock_storage) do |stub|
        stub.post("/logout") { [200, {}, ""] }
      end
      # Set a session so sign_out has something to clear
      mock_storage.set_item("supabase.auth.token", JSON.generate(mock_session))
      client.on_auth_state_change { |event, session| events << [event, session] }

      client.sign_out

      signed_out = events.select { |e| e[0] == "SIGNED_OUT" }
      expect(signed_out.length).to eq(1)
      expect(signed_out[0][1]).to be_nil
    end
  end

  describe "TOKEN_REFRESHED event" do
    it "emitted on set_session" do
      events = []
      # set_session calls _call_refresh_token which uses /token endpoint
      refreshed_session = mock_session.merge("access_token" => "new-access-token")
      client, _stubs = build_client_with_stubs do |stub|
        stub.post("/token") { [200, {}, JSON.generate(refreshed_session)] }
      end
      client.on_auth_state_change { |event, session| events << [event, session] }

      client.set_session("test-access-token", "test-refresh-token")

      token_refreshed = events.select { |e| e[0] == "TOKEN_REFRESHED" }
      expect(token_refreshed.length).to eq(1)
      expect(token_refreshed[0][1]).to be_a(Supabase::Auth::Types::Session)
    end
  end

  describe "USER_UPDATED event" do
    it "emitted on update_user" do
      events = []
      updated_user = mock_user.merge("email" => "new@example.com")
      client, _stubs = build_client_with_stubs(persist_session: true, storage: mock_storage) do |stub|
        stub.put("/user") { [200, {}, JSON.generate({ "user" => updated_user })] }
      end
      mock_storage.set_item("supabase.auth.token", JSON.generate(mock_session))
      client.on_auth_state_change { |event, session| events << [event, session] }

      client.update_user(email: "new@example.com")

      user_updated = events.select { |e| e[0] == "USER_UPDATED" }
      expect(user_updated.length).to eq(1)
      expect(user_updated[0][1]).to be_a(Supabase::Auth::Types::Session)
    end
  end

  describe "PASSWORD_RECOVERY event" do
    it "emitted on initialize_from_url with recovery redirect" do
      events = []
      client, _stubs = build_client_with_stubs do |stub|
        stub.get("/user") { [200, {}, JSON.generate(mock_user)] }
      end
      client.on_auth_state_change { |event, session| events << [event, session] }

      url = "http://localhost:9999/callback?access_token=test-token&refresh_token=test-refresh&expires_in=3600&token_type=bearer&type=recovery"
      client.initialize_from_url(url)

      event_names = events.map(&:first)
      expect(event_names).to include("SIGNED_IN")
      expect(event_names).to include("PASSWORD_RECOVERY")
    end

    it "not emitted when redirect type is not recovery" do
      events = []
      client, _stubs = build_client_with_stubs do |stub|
        stub.get("/user") { [200, {}, JSON.generate(mock_user)] }
      end
      client.on_auth_state_change { |event, session| events << [event, session] }

      url = "http://localhost:9999/callback?access_token=test-token&refresh_token=test-refresh&expires_in=3600&token_type=bearer&type=signup"
      client.initialize_from_url(url)

      event_names = events.map(&:first)
      expect(event_names).to include("SIGNED_IN")
      expect(event_names).not_to include("PASSWORD_RECOVERY")
    end
  end

  describe "MFA_CHALLENGE_VERIFIED event" do
    it "emitted on MFA verify" do
      events = []
      mfa_response = mock_session.dup
      client, _stubs = build_client_with_stubs(persist_session: true, storage: mock_storage) do |stub|
        stub.post("/factors/factor-123/verify") { [200, {}, JSON.generate(mfa_response)] }
      end
      mock_storage.set_item("supabase.auth.token", JSON.generate(mock_session))
      client.on_auth_state_change { |event, session| events << [event, session] }

      client.mfa.verify(factor_id: "factor-123", challenge_id: "challenge-123", code: "123456")

      mfa_verified = events.select { |e| e[0] == "MFA_CHALLENGE_VERIFIED" }
      expect(mfa_verified.length).to eq(1)
      expect(mfa_verified[0][1]).to be_a(Supabase::Auth::Types::Session)
    end
  end

  # ─── AC-3: Multiple subscribers receive events ───

  describe "multiple subscribers" do
    it "all subscribers receive the same event" do
      events1 = []
      events2 = []
      events3 = []
      client, _stubs = build_client_with_stubs do |stub|
        stub.post("/signup") { [200, {}, JSON.generate(mock_session)] }
      end

      client.on_auth_state_change { |event, session| events1 << [event, session] }
      client.on_auth_state_change { |event, session| events2 << [event, session] }
      client.on_auth_state_change { |event, session| events3 << [event, session] }

      client.sign_up(email: "test@example.com", password: "password123")

      expect(events1.length).to eq(1)
      expect(events2.length).to eq(1)
      expect(events3.length).to eq(1)
      expect(events1[0][0]).to eq("SIGNED_IN")
      expect(events2[0][0]).to eq("SIGNED_IN")
      expect(events3[0][0]).to eq("SIGNED_IN")
    end

    it "each subscriber gets the same session object" do
      sessions = []
      client, _stubs = build_client_with_stubs do |stub|
        stub.post("/signup") { [200, {}, JSON.generate(mock_session)] }
      end

      client.on_auth_state_change { |_event, session| sessions << session }
      client.on_auth_state_change { |_event, session| sessions << session }

      client.sign_up(email: "test@example.com", password: "password123")

      expect(sessions.length).to eq(2)
      expect(sessions[0].access_token).to eq(sessions[1].access_token)
    end
  end

  # ─── AC-4: Unsubscribe correctly removes callback ───

  describe "unsubscribe" do
    it "removes the subscriber so it no longer receives events" do
      events = []
      client, _stubs = build_client_with_stubs do |stub|
        stub.post("/signup") { [200, {}, JSON.generate(mock_session)] }
        stub.post("/signup") { [200, {}, JSON.generate(mock_session)] }
      end

      subscription = client.on_auth_state_change { |event, session| events << [event, session] }

      client.sign_up(email: "test@example.com", password: "password123")
      expect(events.length).to eq(1)

      subscription.unsubscribe.call

      client.sign_up(email: "test@example.com", password: "password123")
      expect(events.length).to eq(1) # no new event received
    end

    it "removes only the unsubscribed subscriber, others still receive events" do
      events1 = []
      events2 = []
      client, _stubs = build_client_with_stubs do |stub|
        stub.post("/signup") { [200, {}, JSON.generate(mock_session)] }
        stub.post("/signup") { [200, {}, JSON.generate(mock_session)] }
      end

      sub1 = client.on_auth_state_change { |event, session| events1 << [event, session] }
      client.on_auth_state_change { |event, session| events2 << [event, session] }

      client.sign_up(email: "test@example.com", password: "password123")
      expect(events1.length).to eq(1)
      expect(events2.length).to eq(1)

      sub1.unsubscribe.call

      client.sign_up(email: "test@example.com", password: "password123")
      expect(events1.length).to eq(1) # unsubscribed — no new event
      expect(events2.length).to eq(2) # still subscribed — got new event
    end

    it "removes subscription from _state_change_emitters" do
      client, _stubs = build_client_with_stubs
      subscription = client.on_auth_state_change { |_e, _s| }

      emitters = client.instance_variable_get(:@state_change_emitters)
      expect(emitters).to have_key(subscription.id)

      subscription.unsubscribe.call

      expect(emitters).not_to have_key(subscription.id)
    end

    it "matches Python: uses dict.pop (Ruby: Hash#delete) to remove by ID" do
      client, _stubs = build_client_with_stubs
      sub1 = client.on_auth_state_change { |_e, _s| }
      sub2 = client.on_auth_state_change { |_e, _s| }

      emitters = client.instance_variable_get(:@state_change_emitters)
      expect(emitters.size).to eq(2)

      sub1.unsubscribe.call
      expect(emitters.size).to eq(1)
      expect(emitters).to have_key(sub2.id)
    end
  end

  # ─── AC-5: Events include correct session data ───

  describe "event session data" do
    it "SIGNED_IN event includes session with access_token, refresh_token, user" do
      events = []
      client, _stubs = build_client_with_stubs do |stub|
        stub.post("/signup") { [200, {}, JSON.generate(mock_session)] }
      end
      client.on_auth_state_change { |event, session| events << [event, session] }

      client.sign_up(email: "test@example.com", password: "password123")

      session = events[0][1]
      expect(session.access_token).to eq("test-access-token")
      expect(session.refresh_token).to eq("test-refresh-token")
      expect(session.user).to be_a(Supabase::Auth::Types::User)
      expect(session.user.email).to eq("test@example.com")
    end

    it "SIGNED_OUT event includes nil session" do
      events = []
      client, _stubs = build_client_with_stubs(persist_session: true, storage: mock_storage) do |stub|
        stub.post("/logout") { [200, {}, ""] }
      end
      mock_storage.set_item("supabase.auth.token", JSON.generate(mock_session))
      client.on_auth_state_change { |event, session| events << [event, session] }

      client.sign_out

      signed_out = events.find { |e| e[0] == "SIGNED_OUT" }
      expect(signed_out[1]).to be_nil
    end

    it "TOKEN_REFRESHED event includes refreshed session" do
      events = []
      refreshed = mock_session.merge("access_token" => "refreshed-token")
      client, _stubs = build_client_with_stubs do |stub|
        stub.post("/token") { [200, {}, JSON.generate(refreshed)] }
      end
      client.on_auth_state_change { |event, session| events << [event, session] }

      client.set_session("old-token", "test-refresh-token")

      token_refreshed = events.find { |e| e[0] == "TOKEN_REFRESHED" }
      expect(token_refreshed[1]).to be_a(Supabase::Auth::Types::Session)
    end

    it "USER_UPDATED event includes session with updated user" do
      events = []
      updated_user = mock_user.merge("email" => "updated@example.com")
      client, _stubs = build_client_with_stubs(persist_session: true, storage: mock_storage) do |stub|
        stub.put("/user") { [200, {}, JSON.generate({ "user" => updated_user })] }
      end
      mock_storage.set_item("supabase.auth.token", JSON.generate(mock_session))
      client.on_auth_state_change { |event, session| events << [event, session] }

      client.update_user(email: "updated@example.com")

      user_updated = events.find { |e| e[0] == "USER_UPDATED" }
      expect(user_updated[1]).to be_a(Supabase::Auth::Types::Session)
      expect(user_updated[1].user.email).to eq("updated@example.com")
    end

    it "PASSWORD_RECOVERY event includes session" do
      events = []
      client, _stubs = build_client_with_stubs do |stub|
        stub.get("/user") { [200, {}, JSON.generate(mock_user)] }
      end
      client.on_auth_state_change { |event, session| events << [event, session] }

      url = "http://localhost:9999/callback?access_token=recovery-token&refresh_token=test-refresh&expires_in=3600&token_type=bearer&type=recovery"
      client.initialize_from_url(url)

      recovery = events.find { |e| e[0] == "PASSWORD_RECOVERY" }
      expect(recovery[1]).to be_a(Supabase::Auth::Types::Session)
      expect(recovery[1].access_token).to eq("recovery-token")
    end
  end

  # ─── Parity checks: Python vs Ruby ───

  describe "Python parity" do
    it "Subscription struct matches Python's Subscription model (id, callback, unsubscribe)" do
      members = Supabase::Auth::Types::Subscription.members
      expect(members).to contain_exactly(:id, :callback, :unsubscribe)
    end

    it "_notify_all_subscribers iterates values like Python's for subscription in values()" do
      client, _stubs = build_client_with_stubs
      call_order = []

      client.on_auth_state_change { |_e, _s| call_order << :first }
      client.on_auth_state_change { |_e, _s| call_order << :second }

      client.send(:_notify_all_subscribers, "TEST_EVENT", nil)

      expect(call_order).to eq(%i[first second])
    end

    it "safe navigation (&.call) handles nil callback gracefully (Ruby enhancement)" do
      client, _stubs = build_client_with_stubs
      # Create a subscription with nil callback
      sub = Supabase::Auth::Types::Subscription.new(
        id: "test",
        callback: nil,
        unsubscribe: -> {}
      )
      client.instance_variable_get(:@state_change_emitters)["test"] = sub

      # Should not raise — Ruby uses &.call while Python would crash on None()
      expect { client.send(:_notify_all_subscribers, "TEST", nil) }.not_to raise_error
    end

    it "sign_up without session does not emit SIGNED_IN (matching Python)" do
      events = []
      # Response without session (e.g., email confirmation required)
      no_session_response = { "user" => mock_user }
      client, _stubs = build_client_with_stubs do |stub|
        stub.post("/signup") { [200, {}, JSON.generate(no_session_response)] }
      end
      client.on_auth_state_change { |event, session| events << [event, session] }

      client.sign_up(email: "test@example.com", password: "password123")

      expect(events).to be_empty
    end

    it "emitter storage matches Python: dict keyed by UUID string" do
      client, _stubs = build_client_with_stubs
      emitters = client.instance_variable_get(:@state_change_emitters)

      expect(emitters).to be_a(Hash)
      expect(emitters).to be_empty

      sub = client.on_auth_state_change { |_e, _s| }
      expect(emitters.keys).to eq([sub.id])
      expect(emitters.values.first).to be_a(Supabase::Auth::Types::Subscription)
    end
  end
end
