# frozen_string_literal: true

require "webmock/rspec"

RSpec.describe Supabase::Auth::Client, "event subscription system" do
  let(:url) { "http://localhost:9999" }
  let(:headers) { { "apikey" => "test-api-key" } }
  let(:client) { described_class.new(url: url, headers: headers) }

  before do
    WebMock.disable_net_connect!
  end

  after do
    WebMock.allow_net_connect!
  end

  # Helper: stub endpoints for sign-in flows
  let(:user_data) do
    {
      "id" => "user-123",
      "aud" => "authenticated",
      "role" => "authenticated",
      "email" => "test@example.com",
      "app_metadata" => {},
      "user_metadata" => {},
      "created_at" => "2024-01-01T00:00:00Z"
    }
  end

  let(:session_data) do
    {
      "access_token" => "access-token-123",
      "refresh_token" => "refresh-token-123",
      "token_type" => "bearer",
      "expires_in" => 3600,
      "expires_at" => Time.now.to_i + 3600,
      "user" => user_data
    }
  end

  # -------------------------------------------------------------------
  # AC 1: on_auth_state_change accepts callback and returns Subscription
  # -------------------------------------------------------------------
  describe "#on_auth_state_change" do
    it "returns a Subscription object" do
      # Python: returns Subscription(id=unique_id, callback=callback, unsubscribe=_unsubscribe)
      subscription = client.on_auth_state_change { |_event, _session| }

      expect(subscription).to be_a(Supabase::Auth::Types::Subscription)
    end

    it "returns Subscription with id, callback, and unsubscribe" do
      # Python: Subscription has id: str, callback: Callable, unsubscribe: Callable
      subscription = client.on_auth_state_change { |_event, _session| }

      expect(subscription.id).to be_a(String)
      expect(subscription.id).to match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/) # UUID format
      expect(subscription.callback).to be_a(Proc)
      expect(subscription.unsubscribe).to be_a(Proc)
    end

    it "generates unique IDs for each subscription" do
      # Python: unique_id = str(uuid4())
      sub1 = client.on_auth_state_change { |_e, _s| }
      sub2 = client.on_auth_state_change { |_e, _s| }

      expect(sub1.id).not_to eq(sub2.id)
    end
  end

  # -------------------------------------------------------------------
  # AC 2: All auth events emitted correctly
  # -------------------------------------------------------------------
  describe "auth event emission" do
    it "emits SIGNED_IN on sign_up with session" do
      stub_request(:post, "#{url}/signup")
        .to_return(status: 200, body: session_data.to_json,
                   headers: { "Content-Type" => "application/json" })

      events = []
      client.on_auth_state_change { |event, _s| events << event }
      client.sign_up(email: "test@example.com", password: "password123")

      expect(events).to include("SIGNED_IN")
    end

    it "emits SIGNED_IN on sign_in_with_password" do
      stub_request(:post, "#{url}/token?grant_type=password")
        .to_return(status: 200, body: session_data.to_json,
                   headers: { "Content-Type" => "application/json" })

      events = []
      client.on_auth_state_change { |event, _s| events << event }
      client.sign_in_with_password(email: "test@example.com", password: "password123")

      expect(events).to include("SIGNED_IN")
    end

    it "emits SIGNED_IN on sign_in_anonymously" do
      stub_request(:post, "#{url}/signup")
        .to_return(status: 200, body: session_data.to_json,
                   headers: { "Content-Type" => "application/json" })

      events = []
      client.on_auth_state_change { |event, _s| events << event }
      client.sign_in_anonymously

      expect(events).to include("SIGNED_IN")
    end

    it "emits SIGNED_IN on sign_in_with_id_token" do
      stub_request(:post, "#{url}/token?grant_type=id_token")
        .to_return(status: 200, body: session_data.to_json,
                   headers: { "Content-Type" => "application/json" })

      events = []
      client.on_auth_state_change { |event, _s| events << event }
      client.sign_in_with_id_token(provider: "google", token: "google-id-token")

      expect(events).to include("SIGNED_IN")
    end

    it "emits SIGNED_IN on verify_otp with session" do
      stub_request(:post, "#{url}/verify")
        .to_return(status: 200, body: session_data.to_json,
                   headers: { "Content-Type" => "application/json" })

      events = []
      client.on_auth_state_change { |event, _s| events << event }
      client.verify_otp(email: "test@example.com", token: "123456", type: "email")

      expect(events).to include("SIGNED_IN")
    end

    it "emits SIGNED_IN on initialize_from_url" do
      stub_request(:get, "#{url}/user")
        .to_return(status: 200, body: user_data.to_json,
                   headers: { "Content-Type" => "application/json" })

      events = []
      client.on_auth_state_change { |event, _s| events << event }

      redirect_url = "http://example.com/callback?access_token=tok&refresh_token=rt" \
                     "&expires_in=3600&token_type=bearer"
      client.initialize_from_url(redirect_url)

      expect(events).to include("SIGNED_IN")
    end

    it "emits SIGNED_OUT on sign_out" do
      # Set up a session first
      storage = Supabase::Auth::MemoryStorage.new
      storage.set_item("supabase.auth.token", JSON.generate(session_data))
      client = described_class.new(url: url, headers: headers, storage: storage)
      client.initialize_from_storage

      stub_request(:post, "#{url}/logout?scope=global")
        .to_return(status: 204, body: "", headers: {})

      events = []
      client.on_auth_state_change { |event, _s| events << event }
      client.sign_out

      expect(events).to include("SIGNED_OUT")
    end

    it "emits TOKEN_REFRESHED on successful token refresh" do
      stub_request(:post, "#{url}/token?grant_type=refresh_token")
        .to_return(status: 200, body: session_data.to_json,
                   headers: { "Content-Type" => "application/json" })

      events = []
      client.on_auth_state_change { |event, _s| events << event }
      client.refresh_session("refresh-token-123")

      expect(events).to include("TOKEN_REFRESHED")
    end

    it "emits USER_UPDATED on update_user" do
      # Set up a session first
      storage = Supabase::Auth::MemoryStorage.new
      storage.set_item("supabase.auth.token", JSON.generate(session_data))
      client = described_class.new(url: url, headers: headers, storage: storage)
      client.initialize_from_storage

      updated_user = user_data.merge("email" => "new@example.com")
      updated_session = session_data.merge("user" => updated_user)
      stub_request(:put, "#{url}/user")
        .to_return(status: 200, body: updated_user.to_json,
                   headers: { "Content-Type" => "application/json" })

      events = []
      client.on_auth_state_change { |event, _s| events << event }
      client.update_user(email: "new@example.com")

      expect(events).to include("USER_UPDATED")
    end

    it "emits PASSWORD_RECOVERY on recovery redirect" do
      stub_request(:get, "#{url}/user")
        .to_return(status: 200, body: user_data.to_json,
                   headers: { "Content-Type" => "application/json" })

      events = []
      client.on_auth_state_change { |event, _s| events << event }

      redirect_url = "http://example.com/callback?access_token=tok&refresh_token=rt" \
                     "&expires_in=3600&token_type=bearer&type=recovery"
      client.initialize_from_url(redirect_url)

      expect(events).to include("SIGNED_IN")
      expect(events).to include("PASSWORD_RECOVERY")
    end

    it "emits MFA_CHALLENGE_VERIFIED on mfa.verify" do
      # Set up a session first
      storage = Supabase::Auth::MemoryStorage.new
      storage.set_item("supabase.auth.token", JSON.generate(session_data))
      client = described_class.new(url: url, headers: headers, storage: storage)
      client.initialize_from_storage

      # Stub MFA challenge
      challenge_response = {
        "id" => "challenge-123",
        "factor_id" => "factor-123",
        "expires_at" => (Time.now.to_i + 300).to_s
      }
      stub_request(:post, "#{url}/factors/factor-123/challenge")
        .to_return(status: 200, body: challenge_response.to_json,
                   headers: { "Content-Type" => "application/json" })

      # Stub MFA verify — returns session
      stub_request(:post, "#{url}/factors/factor-123/verify")
        .to_return(status: 200, body: session_data.to_json,
                   headers: { "Content-Type" => "application/json" })

      events = []
      client.on_auth_state_change { |event, _s| events << event }
      client.mfa.challenge_and_verify(factor_id: "factor-123", code: "123456")

      expect(events).to include("MFA_CHALLENGE_VERIFIED")
    end
  end

  # -------------------------------------------------------------------
  # AC 3: Multiple subscribers receive events
  # -------------------------------------------------------------------
  describe "multiple subscribers" do
    it "notifies all subscribers when an event occurs" do
      # Python: for subscription in self._state_change_emitters.values():
      #             subscription.callback(event, session)
      stub_request(:post, "#{url}/token?grant_type=password")
        .to_return(status: 200, body: session_data.to_json,
                   headers: { "Content-Type" => "application/json" })

      events1 = []
      events2 = []
      events3 = []

      client.on_auth_state_change { |event, _s| events1 << event }
      client.on_auth_state_change { |event, _s| events2 << event }
      client.on_auth_state_change { |event, _s| events3 << event }

      client.sign_in_with_password(email: "test@example.com", password: "password123")

      expect(events1).to include("SIGNED_IN")
      expect(events2).to include("SIGNED_IN")
      expect(events3).to include("SIGNED_IN")
    end
  end

  # -------------------------------------------------------------------
  # AC 4: Unsubscribe correctly removes callback
  # -------------------------------------------------------------------
  describe "unsubscribe" do
    it "removes the subscriber so it no longer receives events" do
      # Python: def _unsubscribe() -> None: self._state_change_emitters.pop(unique_id)
      stub_request(:post, "#{url}/token?grant_type=password")
        .to_return(status: 200, body: session_data.to_json,
                   headers: { "Content-Type" => "application/json" })

      events1 = []
      events2 = []

      sub1 = client.on_auth_state_change { |event, _s| events1 << event }
      client.on_auth_state_change { |event, _s| events2 << event }

      # Unsubscribe the first listener
      sub1.unsubscribe.call

      client.sign_in_with_password(email: "test@example.com", password: "password123")

      expect(events1).to be_empty
      expect(events2).to include("SIGNED_IN")
    end

    it "only removes the specific subscriber, not others" do
      stub_request(:post, "#{url}/token?grant_type=password")
        .to_return(status: 200, body: session_data.to_json,
                   headers: { "Content-Type" => "application/json" })

      events1 = []
      events2 = []
      events3 = []

      sub1 = client.on_auth_state_change { |event, _s| events1 << event }
      sub2 = client.on_auth_state_change { |event, _s| events2 << event }
      client.on_auth_state_change { |event, _s| events3 << event }

      sub2.unsubscribe.call

      client.sign_in_with_password(email: "test@example.com", password: "password123")

      expect(events1).to include("SIGNED_IN")
      expect(events2).to be_empty
      expect(events3).to include("SIGNED_IN")
    end
  end

  # -------------------------------------------------------------------
  # AC 5: Events include correct session data
  # -------------------------------------------------------------------
  describe "event session data" do
    it "passes session object with SIGNED_IN event" do
      stub_request(:post, "#{url}/token?grant_type=password")
        .to_return(status: 200, body: session_data.to_json,
                   headers: { "Content-Type" => "application/json" })

      received_sessions = []
      client.on_auth_state_change { |_event, session| received_sessions << session }
      client.sign_in_with_password(email: "test@example.com", password: "password123")

      expect(received_sessions.last).to be_a(Supabase::Auth::Types::Session)
      expect(received_sessions.last.access_token).to eq("access-token-123")
    end

    it "passes nil session with SIGNED_OUT event" do
      # Python: self._notify_all_subscribers("SIGNED_OUT", None)
      storage = Supabase::Auth::MemoryStorage.new
      storage.set_item("supabase.auth.token", JSON.generate(session_data))
      client = described_class.new(url: url, headers: headers, storage: storage)
      client.initialize_from_storage

      stub_request(:post, "#{url}/logout?scope=global")
        .to_return(status: 204, body: "", headers: {})

      received_sessions = []
      client.on_auth_state_change { |event, session| received_sessions << [event, session] }
      client.sign_out

      signed_out_event = received_sessions.find { |e, _| e == "SIGNED_OUT" }
      expect(signed_out_event).not_to be_nil
      expect(signed_out_event[1]).to be_nil
    end

    it "passes refreshed session with TOKEN_REFRESHED event" do
      new_session = session_data.merge("access_token" => "refreshed-token")
      stub_request(:post, "#{url}/token?grant_type=refresh_token")
        .to_return(status: 200, body: new_session.to_json,
                   headers: { "Content-Type" => "application/json" })

      received = []
      client.on_auth_state_change { |event, session| received << [event, session] }
      client.refresh_session("refresh-token-123")

      refreshed_event = received.find { |e, _| e == "TOKEN_REFRESHED" }
      expect(refreshed_event).not_to be_nil
      expect(refreshed_event[1]).to be_a(Supabase::Auth::Types::Session)
      expect(refreshed_event[1].access_token).to eq("refreshed-token")
    end

    it "passes updated session with USER_UPDATED event" do
      storage = Supabase::Auth::MemoryStorage.new
      storage.set_item("supabase.auth.token", JSON.generate(session_data))
      client = described_class.new(url: url, headers: headers, storage: storage)
      client.initialize_from_storage

      updated_user = user_data.merge("email" => "updated@example.com")
      stub_request(:put, "#{url}/user")
        .to_return(status: 200, body: updated_user.to_json,
                   headers: { "Content-Type" => "application/json" })

      received = []
      client.on_auth_state_change { |event, session| received << [event, session] }
      client.update_user(email: "updated@example.com")

      user_updated_event = received.find { |e, _| e == "USER_UPDATED" }
      expect(user_updated_event).not_to be_nil
      expect(user_updated_event[1]).to be_a(Supabase::Auth::Types::Session)
    end
  end

  # -------------------------------------------------------------------
  # Parity check: _notify_all_subscribers matches Python
  # -------------------------------------------------------------------
  describe "_notify_all_subscribers" do
    it "calls each subscriber callback with event and session" do
      # Python: for subscription in self._state_change_emitters.values():
      #             subscription.callback(event, session)
      received = []
      client.on_auth_state_change { |event, session| received << [event, session] }

      session = Supabase::Auth::Types::Session.new(
        access_token: "at", refresh_token: "rt", token_type: "bearer",
        expires_in: 3600, expires_at: Time.now.to_i + 3600
      )
      client._notify_all_subscribers("SIGNED_IN", session)

      expect(received.length).to eq(1)
      expect(received[0][0]).to eq("SIGNED_IN")
      expect(received[0][1]).to eq(session)
    end

    it "handles nil callback gracefully" do
      # Ruby uses safe navigation: sub.callback&.call(event, session)
      # This protects against nil callbacks
      subscription = Supabase::Auth::Types::Subscription.new(
        id: "test-id",
        callback: nil,
        unsubscribe: -> {}
      )
      # Manually add to emitters to test nil callback safety
      client.instance_variable_get(:@state_change_emitters)["test-id"] = subscription

      expect {
        client._notify_all_subscribers("SIGNED_IN", nil)
      }.not_to raise_error
    end
  end
end
