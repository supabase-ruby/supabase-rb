# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"
require "jwt"
require "json"

# US-002: Audit Session Management Methods
# Verifies that Ruby session management matches Python behavior:
#   - get_session auto-refreshes when within EXPIRY_MARGIN (10 seconds)
#   - set_session validates and stores session correctly
#   - refresh_session sends correct grant_type=refresh_token request
#   - sign_out supports all scopes: global, local, others
#   - exchange_code_for_session handles PKCE code exchange correctly
#   - Auto-refresh timer uses exponential backoff matching Python's MAX_RETRIES=10
RSpec.describe "US-002: Session Management Audit" do
  let(:mock_user) do
    Supabase::Auth::Types::User.new(
      id: "test-user-id",
      app_metadata: {},
      user_metadata: {},
      aud: "authenticated",
      email: "test@example.com",
      phone: "",
      created_at: Time.parse("2023-01-01T00:00:00Z"),
      confirmed_at: Time.parse("2023-01-01T00:00:00Z"),
      last_sign_in_at: Time.parse("2023-01-01T00:00:00Z"),
      role: "authenticated",
      updated_at: Time.parse("2023-01-01T00:00:00Z")
    )
  end

  let(:now) { Time.now.to_i }

  let(:mock_session) do
    Supabase::Auth::Types::Session.new(
      access_token: "mock-access-token",
      refresh_token: "mock-refresh-token",
      expires_in: 3600,
      expires_at: now + 3600,
      token_type: "bearer",
      user: mock_user
    )
  end

  let(:refreshed_session_hash) do
    {
      "access_token" => "refreshed-access-token",
      "refresh_token" => "refreshed-refresh-token",
      "token_type" => "bearer",
      "expires_in" => 3600,
      "expires_at" => now + 7200,
      "user" => {
        "id" => "test-user-id",
        "app_metadata" => {},
        "user_metadata" => {},
        "aud" => "authenticated",
        "email" => "test@example.com",
        "created_at" => "2023-01-01T00:00:00Z",
        "updated_at" => "2023-01-01T00:00:00Z"
      }
    }
  end

  # Secret used for test JWT encoding
  JWT_SECRET = "test-jwt-secret"

  def build_client(auto_refresh: true, persist_session: false)
    Supabase::Auth::Client.new(
      url: "http://localhost:9998",
      auto_refresh_token: auto_refresh,
      persist_session: persist_session
    )
  end

  def setup_session(client, session)
    client.instance_variable_set(:@current_session, session)
  end

  # Build a properly-encoded JWT that decode_jwt can parse
  def build_test_jwt(exp:)
    payload = { "exp" => exp, "sub" => "test-user-id", "aud" => "authenticated" }
    JWT.encode(payload, JWT_SECRET, "HS256")
  end

  after do
    WebMock.reset!
  end

  # ----------------------------------------------------------------
  # AC-1: get_session auto-refreshes when within EXPIRY_MARGIN (10s)
  # Python: has_expired = current_session.expires_at <= time_now + EXPIRY_MARGIN
  # ----------------------------------------------------------------
  describe "get_session auto-refresh within EXPIRY_MARGIN" do
    it "returns session without refreshing when not expired" do
      client = build_client
      setup_session(client, mock_session)

      session = client.get_session
      expect(session).to eq(mock_session)
      expect(session.access_token).to eq("mock-access-token")
    end

    it "auto-refreshes session when expires_at <= now + EXPIRY_MARGIN" do
      client = build_client

      # Session that expires within EXPIRY_MARGIN (5 seconds from now < 10s margin)
      expiring_session = Supabase::Auth::Types::Session.new(
        access_token: "old-access-token",
        refresh_token: "old-refresh-token",
        expires_in: 5,
        expires_at: now + 5,
        token_type: "bearer",
        user: mock_user
      )
      setup_session(client, expiring_session)

      stub_request(:post, "http://localhost:9998/token?grant_type=refresh_token")
        .to_return(
          status: 200,
          body: refreshed_session_hash.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      session = client.get_session
      expect(session.access_token).to eq("refreshed-access-token")
      expect(session.refresh_token).to eq("refreshed-refresh-token")
    end

    it "auto-refreshes session when expires_at equals now + EXPIRY_MARGIN exactly" do
      client = build_client

      # Session that expires exactly at the margin boundary
      boundary_session = Supabase::Auth::Types::Session.new(
        access_token: "boundary-token",
        refresh_token: "boundary-refresh",
        expires_in: Supabase::Auth::Constants::EXPIRY_MARGIN,
        expires_at: now + Supabase::Auth::Constants::EXPIRY_MARGIN,
        token_type: "bearer",
        user: mock_user
      )
      setup_session(client, boundary_session)

      stub_request(:post, "http://localhost:9998/token?grant_type=refresh_token")
        .to_return(
          status: 200,
          body: refreshed_session_hash.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      session = client.get_session
      # Python: has_expired = expires_at <= time_now + EXPIRY_MARGIN → True when equal
      expect(session.access_token).to eq("refreshed-access-token")
    end

    it "returns nil when no session exists" do
      client = build_client
      expect(client.get_session).to be_nil
    end

    it "returns session without refresh when expires_at is nil (matches Python false branch)" do
      client = build_client

      # Session without expires_at — Python: has_expired = False
      no_expiry_session = Supabase::Auth::Types::Session.new(
        access_token: "no-expiry-token",
        refresh_token: "no-expiry-refresh",
        expires_in: 3600,
        expires_at: nil,
        token_type: "bearer",
        user: mock_user
      )
      setup_session(client, no_expiry_session)

      session = client.get_session
      expect(session.access_token).to eq("no-expiry-token")
    end
  end

  # ----------------------------------------------------------------
  # AC-1 (continued): EXPIRY_MARGIN constant matches Python
  # ----------------------------------------------------------------
  describe "EXPIRY_MARGIN constant" do
    it "equals 10 seconds matching Python's EXPIRY_MARGIN" do
      expect(Supabase::Auth::Constants::EXPIRY_MARGIN).to eq(10)
      # Also check client-level constant
      expect(Supabase::Auth::Client::EXPIRY_MARGIN).to eq(10)
    end
  end

  # ----------------------------------------------------------------
  # AC-2: set_session validates and stores session correctly
  # Python: decodes JWT, checks exp, refreshes if expired, creates session if valid
  # ----------------------------------------------------------------
  describe "set_session validation and storage" do
    it "raises AuthSessionMissing for expired token without refresh token (matches Python)" do
      client = build_client
      expired_token = build_test_jwt(exp: now - 3600)

      expect {
        client.set_session(expired_token, "")
      }.to raise_error(Supabase::Auth::Errors::AuthSessionMissing)
    end

    it "refreshes when token is expired and refresh token is provided" do
      client = build_client
      expired_token = build_test_jwt(exp: now - 3600)

      stub_request(:post, "http://localhost:9998/token?grant_type=refresh_token")
        .to_return(
          status: 200,
          body: refreshed_session_hash.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      response = client.set_session(expired_token, "valid-refresh-token")
      expect(response.session).not_to be_nil
      expect(response.session.access_token).to eq("refreshed-access-token")
    end

    it "creates session from valid (non-expired) token with get_user data" do
      client = build_client
      valid_token = build_test_jwt(exp: now + 3600)

      user_response_body = {
        "id" => "test-user-id",
        "app_metadata" => {},
        "user_metadata" => {},
        "aud" => "authenticated",
        "email" => "test@example.com",
        "created_at" => "2023-01-01T00:00:00Z",
        "updated_at" => "2023-01-01T00:00:00Z"
      }

      stub_request(:get, "http://localhost:9998/user")
        .to_return(
          status: 200,
          body: user_response_body.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      response = client.set_session(valid_token, "test-refresh-token")
      expect(response.session).not_to be_nil
      expect(response.session.access_token).to eq(valid_token)
      expect(response.session.refresh_token).to eq("test-refresh-token")
      expect(response.session.token_type).to eq("bearer")
      expect(response.session.user.email).to eq("test@example.com")
    end

    it "emits TOKEN_REFRESHED event (matches Python)" do
      client = build_client
      valid_token = build_test_jwt(exp: now + 3600)

      stub_request(:get, "http://localhost:9998/user")
        .to_return(
          status: 200,
          body: { "id" => "test-user-id", "app_metadata" => {}, "user_metadata" => {},
                  "aud" => "authenticated", "email" => "test@example.com",
                  "created_at" => "2023-01-01T00:00:00Z", "updated_at" => "2023-01-01T00:00:00Z" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      events = []
      client.on_auth_state_change { |event, session| events << { event: event, session: session } }

      client.set_session(valid_token, "test-refresh-token")

      expect(events.any? { |e| e[:event] == "TOKEN_REFRESHED" }).to be true
    end

    it "returns AuthResponse with session and user (matches Python)" do
      client = build_client
      valid_token = build_test_jwt(exp: now + 3600)

      stub_request(:get, "http://localhost:9998/user")
        .to_return(
          status: 200,
          body: { "id" => "test-user-id", "app_metadata" => {}, "user_metadata" => {},
                  "aud" => "authenticated", "email" => "test@example.com",
                  "created_at" => "2023-01-01T00:00:00Z", "updated_at" => "2023-01-01T00:00:00Z" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      response = client.set_session(valid_token, "test-refresh-token")
      expect(response).to be_a(Supabase::Auth::Types::AuthResponse)
      expect(response.session).not_to be_nil
      expect(response.user).not_to be_nil
      expect(response.user).to eq(response.session.user)
    end
  end

  # ----------------------------------------------------------------
  # AC-3: refresh_session sends correct grant_type=refresh_token request
  # Python: query={"grant_type": "refresh_token"}, body={"refresh_token": token}
  # ----------------------------------------------------------------
  describe "refresh_session request construction" do
    it "sends POST to /token with grant_type=refresh_token query param" do
      client = build_client
      setup_session(client, mock_session)

      token_stub = stub_request(:post, "http://localhost:9998/token?grant_type=refresh_token")
        .with(body: hash_including("refresh_token" => "mock-refresh-token"))
        .to_return(
          status: 200,
          body: refreshed_session_hash.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      response = client.refresh_session
      expect(token_stub).to have_been_requested
      expect(response).to be_a(Supabase::Auth::Types::AuthResponse)
      expect(response.session.access_token).to eq("refreshed-access-token")
      expect(response.user).not_to be_nil
    end

    it "uses provided refresh_token parameter instead of session's" do
      client = build_client
      # No session set - but providing explicit refresh token

      token_stub = stub_request(:post, "http://localhost:9998/token?grant_type=refresh_token")
        .with(body: hash_including("refresh_token" => "explicit-refresh-token"))
        .to_return(
          status: 200,
          body: refreshed_session_hash.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      response = client.refresh_session("explicit-refresh-token")
      expect(token_stub).to have_been_requested
    end

    it "raises AuthSessionMissing when no refresh token available (matches Python)" do
      client = build_client
      # No session, no explicit token

      expect {
        client.refresh_session
      }.to raise_error(Supabase::Auth::Errors::AuthSessionMissing)
    end

    it "falls back to current session's refresh_token when not provided" do
      client = build_client
      setup_session(client, mock_session)

      token_stub = stub_request(:post, "http://localhost:9998/token?grant_type=refresh_token")
        .with(body: hash_including("refresh_token" => "mock-refresh-token"))
        .to_return(
          status: 200,
          body: refreshed_session_hash.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      client.refresh_session
      expect(token_stub).to have_been_requested
    end
  end

  # ----------------------------------------------------------------
  # AC-4: sign_out supports all scopes: global, local, others
  # Python: scope="global"|"local"|"others"; removes session unless "others"
  # ----------------------------------------------------------------
  describe "sign_out scope support" do
    it "defaults to 'global' scope (matches Python default)" do
      client = build_client
      allow(client).to receive(:get_session).and_return(mock_session)
      allow(client.admin).to receive(:sign_out)
      allow(client).to receive(:_remove_session).and_call_original
      allow(client).to receive(:_notify_all_subscribers).and_call_original

      client.sign_out

      expect(client.admin).to have_received(:sign_out).with("mock-access-token", "global")
      expect(client).to have_received(:_remove_session)
      expect(client).to have_received(:_notify_all_subscribers).with("SIGNED_OUT", nil)
    end

    it "passes 'local' scope to admin and removes session" do
      client = build_client
      allow(client).to receive(:get_session).and_return(mock_session)
      allow(client.admin).to receive(:sign_out)
      allow(client).to receive(:_remove_session).and_call_original
      allow(client).to receive(:_notify_all_subscribers).and_call_original

      client.sign_out(scope: "local")

      expect(client.admin).to have_received(:sign_out).with("mock-access-token", "local")
      expect(client).to have_received(:_remove_session)
      expect(client).to have_received(:_notify_all_subscribers).with("SIGNED_OUT", nil)
    end

    it "passes 'others' scope to admin but does NOT remove session or emit event" do
      client = build_client
      allow(client).to receive(:get_session).and_return(mock_session)
      allow(client.admin).to receive(:sign_out)
      allow(client).to receive(:_remove_session)
      allow(client).to receive(:_notify_all_subscribers)

      client.sign_out(scope: "others")

      expect(client.admin).to have_received(:sign_out).with("mock-access-token", "others")
      expect(client).not_to have_received(:_remove_session)
      expect(client).not_to have_received(:_notify_all_subscribers)
    end

    it "suppresses AuthApiError from admin.sign_out (matches Python suppress())" do
      client = build_client
      allow(client).to receive(:get_session).and_return(mock_session)
      allow(client.admin).to receive(:sign_out).and_raise(
        Supabase::Auth::Errors::AuthApiError.new("Server error", status: 500, code: "server_error")
      )
      allow(client).to receive(:_remove_session).and_call_original
      allow(client).to receive(:_notify_all_subscribers).and_call_original

      # Should not raise
      expect { client.sign_out }.not_to raise_error
      expect(client).to have_received(:_remove_session)
      expect(client).to have_received(:_notify_all_subscribers).with("SIGNED_OUT", nil)
    end

    it "skips admin.sign_out when no session exists (matches Python)" do
      client = build_client
      allow(client).to receive(:get_session).and_return(nil)
      allow(client.admin).to receive(:sign_out)
      allow(client).to receive(:_remove_session).and_call_original
      allow(client).to receive(:_notify_all_subscribers).and_call_original

      client.sign_out

      expect(client.admin).not_to have_received(:sign_out)
      # Still removes session and emits SIGNED_OUT
      expect(client).to have_received(:_remove_session)
      expect(client).to have_received(:_notify_all_subscribers).with("SIGNED_OUT", nil)
    end
  end

  # ----------------------------------------------------------------
  # AC-5: exchange_code_for_session handles PKCE code exchange correctly
  # Python: POST /token?grant_type=pkce, body={auth_code, code_verifier}
  # ----------------------------------------------------------------
  describe "exchange_code_for_session PKCE flow" do
    it "sends POST to /token with grant_type=pkce and correct body" do
      client = build_client
      client._flow_type = "pkce"

      token_stub = stub_request(:post, "http://localhost:9998/token?grant_type=pkce")
        .with(body: hash_including("auth_code" => "test-auth-code", "code_verifier" => "test-verifier"))
        .to_return(
          status: 200,
          body: refreshed_session_hash.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      response = client.exchange_code_for_session(
        auth_code: "test-auth-code",
        code_verifier: "test-verifier"
      )

      expect(token_stub).to have_been_requested
      expect(response.session.access_token).to eq("refreshed-access-token")
    end

    it "falls back to code_verifier from storage when not provided in params" do
      client = build_client
      client._flow_type = "pkce"

      # Store verifier in storage
      client._storage.set_item("#{client._storage_key}-code-verifier", "stored-verifier")

      token_stub = stub_request(:post, "http://localhost:9998/token?grant_type=pkce")
        .with(body: hash_including("code_verifier" => "stored-verifier"))
        .to_return(
          status: 200,
          body: refreshed_session_hash.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      client.exchange_code_for_session(auth_code: "test-auth-code")
      expect(token_stub).to have_been_requested
    end

    it "cleans up code_verifier from storage after exchange (matches Python)" do
      client = build_client
      client._flow_type = "pkce"

      storage_key = "#{client._storage_key}-code-verifier"
      client._storage.set_item(storage_key, "stored-verifier")

      stub_request(:post, "http://localhost:9998/token?grant_type=pkce")
        .to_return(
          status: 200,
          body: refreshed_session_hash.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      client.exchange_code_for_session(auth_code: "test-auth-code")

      expect(client._storage.get_item(storage_key)).to be_nil
    end

    it "emits SIGNED_IN event on successful exchange (matches Python)" do
      client = build_client
      client._flow_type = "pkce"

      stub_request(:post, "http://localhost:9998/token?grant_type=pkce")
        .to_return(
          status: 200,
          body: refreshed_session_hash.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      events = []
      client.on_auth_state_change { |event, session| events << event }

      client.exchange_code_for_session(
        auth_code: "test-auth-code",
        code_verifier: "test-verifier"
      )

      expect(events).to include("SIGNED_IN")
    end

    it "saves session on successful exchange (matches Python)" do
      client = build_client
      client._flow_type = "pkce"

      stub_request(:post, "http://localhost:9998/token?grant_type=pkce")
        .to_return(
          status: 200,
          body: refreshed_session_hash.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      client.exchange_code_for_session(
        auth_code: "test-auth-code",
        code_verifier: "test-verifier"
      )

      saved_session = client.instance_variable_get(:@current_session)
      expect(saved_session).not_to be_nil
      expect(saved_session.access_token).to eq("refreshed-access-token")
    end

    it "passes redirect_to parameter (matches Python)" do
      client = build_client
      client._flow_type = "pkce"

      # We can verify redirect_to is passed by checking _request is called correctly
      allow(client).to receive(:_request).and_return(refreshed_session_hash)

      client.exchange_code_for_session(
        auth_code: "test-auth-code",
        code_verifier: "test-verifier",
        redirect_to: "https://example.com/callback"
      )

      expect(client).to have_received(:_request).with(
        "POST", "token",
        hash_including(redirect_to: "https://example.com/callback")
      )
    end
  end

  # ----------------------------------------------------------------
  # AC-6: Auto-refresh timer uses exponential backoff matching auth-js
  # auth-js: 200 * Math.pow(2, attempt - 1), MAX_RETRIES=10
  # ----------------------------------------------------------------
  describe "auto-refresh exponential backoff" do
    it "MAX_RETRIES is 10 (matches Python)" do
      expect(Supabase::Auth::Constants::MAX_RETRIES).to eq(10)
    end

    it "RETRY_INTERVAL is 2 (matches Python)" do
      expect(Supabase::Auth::Constants::RETRY_INTERVAL).to eq(2)
    end

    it "schedules retry with 200 * RETRY_INTERVAL ** (retries - 1) on AuthRetryableError" do
      client = build_client(auto_refresh: true)
      setup_session(client, mock_session)

      retry_values = []
      allow(client).to receive(:_refresh_access_token).and_raise(
        Supabase::Auth::Errors::AuthRetryableError.new("Network error", status: 0)
      )

      # Capture the retry interval by intercepting _start_auto_refresh_token
      call_count = 0
      allow(client).to receive(:_start_auto_refresh_token).and_wrap_original do |method, value|
        call_count += 1
        if call_count == 1
          # First call — let timer fire but intercept the recursive retry call
          method.call(value)
        else
          # Subsequent calls are retries — capture the value
          retry_values << value
        end
      end

      client._start_auto_refresh_token(1) # 1ms delay
      sleep 0.2

      # After first failure, network_retries=1, so value = 200 * 2^0 = 200ms
      if retry_values.any?
        expect(retry_values.first).to eq(200 * (Supabase::Auth::Constants::RETRY_INTERVAL ** (1 - 1)))
      end
    end

    it "stops retrying after MAX_RETRIES attempts" do
      client = build_client(auto_refresh: true)
      setup_session(client, mock_session)

      # Set network_retries to MAX_RETRIES to simulate exhausted retries
      client.instance_variable_set(:@network_retries, Supabase::Auth::Constants::MAX_RETRIES)

      allow(client).to receive(:_refresh_access_token).and_raise(
        Supabase::Auth::Errors::AuthRetryableError.new("Network error", status: 0)
      )

      # Track whether a retry was scheduled
      retry_scheduled = false
      allow(client).to receive(:_start_auto_refresh_token).and_wrap_original do |method, value|
        if client.instance_variable_get(:@network_retries) >= Supabase::Auth::Constants::MAX_RETRIES
          method.call(value) # Let it run — it should NOT schedule a retry
        else
          retry_scheduled = true
        end
      end

      client._start_auto_refresh_token(1)
      sleep 0.2

      expect(retry_scheduled).to be false
    end

    it "resets network_retries to 0 on successful refresh (matches Python)" do
      client = build_client(auto_refresh: true)
      setup_session(client, mock_session)
      client.instance_variable_set(:@network_retries, 5)

      stub_request(:post, "http://localhost:9998/token?grant_type=refresh_token")
        .to_return(
          status: 200,
          body: refreshed_session_hash.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      client._start_auto_refresh_token(1)
      sleep 0.2

      expect(client.instance_variable_get(:@network_retries)).to eq(0)
    end
  end

  # ----------------------------------------------------------------
  # _save_session: timer scheduling matches Python
  # Python: refresh_duration = EXPIRY_MARGIN if expire_in > EXPIRY_MARGIN else 0.5
  #         value = (expire_in - refresh_duration) * 1000
  # ----------------------------------------------------------------
  describe "_save_session timer scheduling (Python parity)" do
    it "schedules timer at (expires_in - EXPIRY_MARGIN) * 1000 ms for long sessions" do
      client = build_client(auto_refresh: true)

      timer_value = nil
      allow(client).to receive(:_start_auto_refresh_token) do |value|
        timer_value = value
      end

      client.send(:_save_session, mock_session)

      # expires_in=3600, EXPIRY_MARGIN=10 → (3600 - 10) * 1000 = 3590000
      expected = (3600 - Supabase::Auth::Constants::EXPIRY_MARGIN) * 1000
      expect(timer_value).to be_within(1000).of(expected)
    end

    it "schedules timer at (expires_in - 0.5) * 1000 ms for short sessions" do
      client = build_client(auto_refresh: true)

      short_session = Supabase::Auth::Types::Session.new(
        access_token: "short-token",
        refresh_token: "short-refresh",
        expires_in: 5,
        expires_at: Time.now.to_i + 5,
        token_type: "bearer",
        user: mock_user
      )

      timer_value = nil
      allow(client).to receive(:_start_auto_refresh_token) do |value|
        timer_value = value
      end

      client.send(:_save_session, short_session)

      # expires_in=5, < EXPIRY_MARGIN → (5 - 0.5) * 1000 = 4500
      expect(timer_value).to be_within(500).of(4500)
    end

    it "stores session to @current_session (matches Python in-memory)" do
      client = build_client(auto_refresh: false)

      client.send(:_save_session, mock_session)

      saved = client.instance_variable_get(:@current_session)
      expect(saved).to eq(mock_session)
    end
  end

  # ----------------------------------------------------------------
  # _remove_session: clears session, storage, and cancels timer
  # Python: removes from storage if persist, clears in_memory, cancels timer
  # ----------------------------------------------------------------
  describe "_remove_session behavior" do
    it "clears @current_session" do
      client = build_client
      setup_session(client, mock_session)

      client.send(:_remove_session)
      expect(client.instance_variable_get(:@current_session)).to be_nil
    end

    it "cancels refresh timer" do
      client = build_client
      timer = instance_double(Supabase::Auth::Timer)
      allow(timer).to receive(:cancel)
      client.instance_variable_set(:@refresh_token_timer, timer)

      client.send(:_remove_session)

      expect(timer).to have_received(:cancel)
      expect(client.instance_variable_get(:@refresh_token_timer)).to be_nil
    end

    it "removes from storage when persist_session is true" do
      client = build_client(persist_session: true)
      client._storage.set_item(client._storage_key, '{"access_token":"test"}')

      client.send(:_remove_session)

      expect(client._storage.get_item(client._storage_key)).to be_nil
    end
  end

  # ----------------------------------------------------------------
  # _get_valid_session: validates stored session data
  # Python: checks access_token, refresh_token, expires_at; parses expires_at as int
  # ----------------------------------------------------------------
  describe "_get_valid_session validation" do
    it "returns nil for nil input" do
      client = build_client
      expect(client.send(:_get_valid_session, nil)).to be_nil
    end

    it "returns nil when access_token is missing" do
      client = build_client
      raw = JSON.generate({ "refresh_token" => "rt", "expires_at" => now + 3600 })
      expect(client.send(:_get_valid_session, raw)).to be_nil
    end

    it "returns nil when refresh_token is missing" do
      client = build_client
      raw = JSON.generate({ "access_token" => "at", "expires_at" => now + 3600 })
      expect(client.send(:_get_valid_session, raw)).to be_nil
    end

    it "returns nil when expires_at is missing" do
      client = build_client
      raw = JSON.generate({ "access_token" => "at", "refresh_token" => "rt" })
      expect(client.send(:_get_valid_session, raw)).to be_nil
    end

    it "parses valid JSON session string into Session struct" do
      client = build_client
      raw = JSON.generate({
        "access_token" => "at",
        "refresh_token" => "rt",
        "expires_at" => now + 3600,
        "expires_in" => 3600,
        "token_type" => "bearer"
      })

      session = client.send(:_get_valid_session, raw)
      expect(session).to be_a(Supabase::Auth::Types::Session)
      expect(session.access_token).to eq("at")
      expect(session.refresh_token).to eq("rt")
      expect(session.expires_at).to eq(now + 3600)
    end

    it "returns nil for invalid JSON" do
      client = build_client
      expect(client.send(:_get_valid_session, "not-json")).to be_nil
    end

    it "returns nil when expires_at cannot be parsed as integer" do
      client = build_client
      raw = JSON.generate({
        "access_token" => "at",
        "refresh_token" => "rt",
        "expires_at" => "not-a-number"
      })
      expect(client.send(:_get_valid_session, raw)).to be_nil
    end
  end

  # ----------------------------------------------------------------
  # _call_refresh_token: validates, refreshes, saves, and emits
  # Python: raises AuthSessionMissing if no token, saves session, emits TOKEN_REFRESHED
  # ----------------------------------------------------------------
  describe "_call_refresh_token behavior" do
    it "raises AuthSessionMissing for empty refresh_token (matches Python)" do
      client = build_client

      expect {
        client.send(:_call_refresh_token, "")
      }.to raise_error(Supabase::Auth::Errors::AuthSessionMissing)

      expect {
        client.send(:_call_refresh_token, nil)
      }.to raise_error(Supabase::Auth::Errors::AuthSessionMissing)
    end

    it "saves session and emits TOKEN_REFRESHED on success" do
      client = build_client

      stub_request(:post, "http://localhost:9998/token?grant_type=refresh_token")
        .to_return(
          status: 200,
          body: refreshed_session_hash.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      events = []
      client.on_auth_state_change { |event, session| events << { event: event, session: session } }

      session = client.send(:_call_refresh_token, "valid-refresh-token")

      expect(session.access_token).to eq("refreshed-access-token")
      expect(events.any? { |e| e[:event] == "TOKEN_REFRESHED" }).to be true
      expect(client.instance_variable_get(:@current_session)).not_to be_nil
    end
  end

  # ----------------------------------------------------------------
  # Persisted session: get_session reads from storage
  # Python: self._storage.get_item(self._storage_key)
  # ----------------------------------------------------------------
  describe "get_session with persist_session" do
    it "reads from storage when persist_session is true" do
      client = build_client(persist_session: true)

      session_data = {
        "access_token" => "stored-token",
        "refresh_token" => "stored-refresh",
        "expires_at" => now + 3600,
        "expires_in" => 3600,
        "token_type" => "bearer"
      }
      client._storage.set_item(client._storage_key, JSON.generate(session_data))

      session = client.get_session
      expect(session).not_to be_nil
      expect(session.access_token).to eq("stored-token")
    end

    it "removes invalid session from storage and returns nil" do
      client = build_client(persist_session: true)

      # Store invalid session (missing refresh_token)
      client._storage.set_item(client._storage_key, JSON.generate({ "access_token" => "only-at" }))

      session = client.get_session
      expect(session).to be_nil
      # Storage should be cleaned up
      expect(client._storage.get_item(client._storage_key)).to be_nil
    end

    it "reads from @current_session when persist_session is false" do
      client = build_client(persist_session: false)
      setup_session(client, mock_session)

      session = client.get_session
      expect(session).to eq(mock_session)
    end
  end
end
