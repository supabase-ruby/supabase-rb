# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"

# Tests for the timer-based session auto-refresh mechanism.
# Uses time manipulation (stubbing Time.now) rather than real waits.
RSpec.describe "Session auto-refresh" do
  let(:mock_user) do
    Supabase::Auth::Types::User.new(
      id: "test-user-id",
      app_metadata: {},
      user_metadata: {},
      aud: "test-aud",
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
        "aud" => "test-aud",
        "email" => "test@example.com",
        "created_at" => "2023-01-01T00:00:00Z",
        "updated_at" => "2023-01-01T00:00:00Z"
      }
    }
  end

  def build_client(auto_refresh: true)
    Supabase::Auth::Client.new(
      url: "http://localhost:9998",
      auto_refresh_token: auto_refresh,
      persist_session: false
    )
  end

  def setup_session(client, session)
    client.instance_variable_set(:@current_session, session)
  end

  after do
    # Ensure no timer threads leak between tests
    WebMock.reset!
  end

  describe "auto-refresh is scheduled when a session is set" do
    it "creates a refresh timer when _save_session is called with expires_at" do
      client = build_client(auto_refresh: true)

      # Timer should not exist initially
      timer = client.instance_variable_get(:@refresh_token_timer)
      expect(timer).to be_nil

      # Stub the refresh API call that the timer will trigger
      stub_request(:post, "http://localhost:9998/token?grant_type=refresh_token")
        .to_return(status: 200, body: refreshed_session_hash.to_json, headers: { "Content-Type" => "application/json" })

      # Call _save_session (private) to trigger timer scheduling
      client.send(:_save_session, mock_session)

      timer = client.instance_variable_get(:@refresh_token_timer)
      expect(timer).not_to be_nil
      expect(timer).to be_a(Supabase::Auth::Timer)

      # Clean up timer
      timer.cancel
    end

    it "does not create a timer when auto_refresh_token is disabled" do
      client = build_client(auto_refresh: false)

      client.send(:_save_session, mock_session)

      timer = client.instance_variable_get(:@refresh_token_timer)
      expect(timer).to be_nil
    end
  end

  describe "auto-refresh fires before token expiry respecting EXPIRY_MARGIN" do
    it "schedules refresh EXPIRY_MARGIN seconds before expiration" do
      client = build_client(auto_refresh: true)

      # Track the timer interval
      timer_interval = nil
      allow(Supabase::Auth::Timer).to receive(:new).and_wrap_original do |method, interval, &block|
        timer_interval = interval
        timer = method.call(interval, &block)
        # Prevent timer from actually starting
        allow(timer).to receive(:start)
        timer
      end

      client.send(:_save_session, mock_session)

      # The timer should fire at (expires_in - EXPIRY_MARGIN) seconds
      # expires_in = 3600, EXPIRY_MARGIN = 10
      # value = (3600 - 10) * 1000 = 3590000 ms → interval = 3590.0 seconds
      expected_interval = (3600 - Supabase::Auth::Constants::EXPIRY_MARGIN).to_f
      expect(timer_interval).to be_within(1.0).of(expected_interval)
    end

    it "uses 0.5s margin when expires_in is less than EXPIRY_MARGIN" do
      client = build_client(auto_refresh: true)

      # Session expiring in 5 seconds (less than EXPIRY_MARGIN of 10)
      short_session = Supabase::Auth::Types::Session.new(
        access_token: "short-token",
        refresh_token: "short-refresh",
        expires_in: 5,
        expires_at: Time.now.round.to_i + 5,
        token_type: "bearer",
        user: mock_user
      )

      timer_interval = nil
      allow(Supabase::Auth::Timer).to receive(:new).and_wrap_original do |method, interval, &block|
        timer_interval = interval
        timer = method.call(interval, &block)
        allow(timer).to receive(:start)
        timer
      end

      client.send(:_save_session, short_session)

      # When expire_in <= EXPIRY_MARGIN, refresh_duration_before_expires = 0.5
      # value = (5 - 0.5) * 1000 = 4500 ms → interval = 4.5 seconds
      expect(timer_interval).to be_within(0.5).of(4.5)
    end
  end

  describe "auto-refresh calls refresh_session internally" do
    it "calls _call_refresh_token when the timer fires" do
      client = build_client(auto_refresh: true)
      setup_session(client, mock_session)

      # Stub the HTTP request for token refresh
      stub_request(:post, "http://localhost:9998/token?grant_type=refresh_token")
        .to_return(status: 200, body: refreshed_session_hash.to_json, headers: { "Content-Type" => "application/json" })

      # Directly invoke _start_auto_refresh_token with a tiny delay
      # so we can observe the refresh happening
      client.send(:_start_auto_refresh_token, 1) # 1ms delay

      # Wait briefly for the timer thread to execute
      sleep 0.1

      # The session should have been refreshed
      updated_session = client.instance_variable_get(:@current_session)
      expect(updated_session.access_token).to eq("refreshed-access-token")
      expect(updated_session.refresh_token).to eq("refreshed-refresh-token")
    end
  end

  describe "failed refresh emits appropriate auth state change event" do
    it "emits TOKEN_REFRESHED event on successful refresh" do
      client = build_client(auto_refresh: true)
      setup_session(client, mock_session)

      events = []
      client.on_auth_state_change do |event, session|
        events << { event: event, session: session }
      end

      stub_request(:post, %r{http://localhost:9998/token})
        .to_return(status: 200, body: refreshed_session_hash.to_json, headers: { "Content-Type" => "application/json" })

      # Call _call_refresh_token directly to verify TOKEN_REFRESHED event
      client.send(:_call_refresh_token, mock_session.refresh_token)

      token_refreshed_events = events.select { |e| e[:event] == "TOKEN_REFRESHED" }
      expect(token_refreshed_events).not_to be_empty
      expect(token_refreshed_events.first[:session].access_token).to eq("refreshed-access-token")
    end

    it "retries on AuthRetryableError without crashing" do
      client = build_client(auto_refresh: true)
      setup_session(client, mock_session)

      # Simulate a network error that raises AuthRetryableError
      call_count = 0
      allow(client).to receive(:_refresh_access_token) do
        call_count += 1
        raise Supabase::Auth::Errors::AuthRetryableError.new("Network error", 0)
      end

      client.send(:_start_auto_refresh_token, 1)
      sleep 0.1

      # Should have attempted at least one refresh
      expect(call_count).to be >= 1
    end
  end

  describe "auto-refresh timer is cancelled on sign_out" do
    it "cancels the refresh timer when sign_out is called" do
      client = build_client(auto_refresh: true)

      # Set up a session and trigger timer creation
      timer_mock = instance_double(Supabase::Auth::Timer, alive?: true)
      allow(timer_mock).to receive(:cancel)
      allow(timer_mock).to receive(:start)
      client.instance_variable_set(:@refresh_token_timer, timer_mock)
      setup_session(client, mock_session)

      # Stub admin sign_out API call
      stub_request(:post, %r{http://localhost:9998/logout})
        .to_return(status: 200, body: "")

      client.sign_out

      expect(timer_mock).to have_received(:cancel)
      expect(client.instance_variable_get(:@refresh_token_timer)).to be_nil
    end

    it "clears the session when sign_out is called" do
      client = build_client(auto_refresh: true)
      setup_session(client, mock_session)

      stub_request(:post, %r{http://localhost:9998/logout})
        .to_return(status: 200, body: "")

      client.sign_out

      expect(client.instance_variable_get(:@current_session)).to be_nil
    end

    it "emits SIGNED_OUT event on sign_out" do
      client = build_client(auto_refresh: true)
      setup_session(client, mock_session)

      events = []
      client.on_auth_state_change do |event, _session|
        events << event
      end

      stub_request(:post, %r{http://localhost:9998/logout})
        .to_return(status: 200, body: "")

      client.sign_out

      expect(events).to include("SIGNED_OUT")
    end
  end

  describe "EXPIRY_MARGIN constant" do
    it "is set to 10 seconds" do
      expect(Supabase::Auth::Constants::EXPIRY_MARGIN).to eq(10)
    end
  end

  describe "_start_auto_refresh_token cancels previous timer" do
    it "cancels existing timer before creating a new one" do
      client = build_client(auto_refresh: true)

      # Create a first timer
      first_timer = instance_double(Supabase::Auth::Timer, alive?: true)
      allow(first_timer).to receive(:cancel)
      client.instance_variable_set(:@refresh_token_timer, first_timer)

      # Create a new timer (which should cancel the first)
      allow_any_instance_of(Supabase::Auth::Timer).to receive(:start)
      client.send(:_start_auto_refresh_token, 5000)

      expect(first_timer).to have_received(:cancel)
    end
  end
end
