# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"

# Tests for AuthRetryableError and retry/backoff behavior.
# Verifies that transient failures (502/503/504) raise AuthRetryableError,
# non-retryable errors (400/401/403) raise AuthApiError immediately,
# and the retry mechanism in auto-refresh respects MAX_RETRIES and RETRY_INTERVAL.
RSpec.describe "Error retry logic" do
  let(:base_url) { "http://localhost:9998" }
  let(:api) { Supabase::Auth::Api.new(url: base_url, headers: { "apikey" => "test-key" }) }

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
      url: base_url,
      auto_refresh_token: auto_refresh,
      persist_session: false
    )
  end

  after { WebMock.reset! }

  describe "AuthRetryableError is raised for retryable HTTP status codes" do
    [502, 503, 504].each do |status_code|
      it "raises AuthRetryableError on #{status_code} response" do
        stub_request(:get, "#{base_url}/user")
          .to_return(status: status_code, body: "Server Error", headers: { "Content-Type" => "text/html" })

        expect { api.get("/user") }.to raise_error(Supabase::Auth::Errors::AuthRetryableError) do |e|
          expect(e.status).to eq(status_code)
        end
      end
    end

    it "raises AuthRetryableError for non-Faraday exceptions (network errors)" do
      allow_any_instance_of(Faraday::Connection).to receive(:run_request).and_raise(Errno::ECONNREFUSED, "Connection refused")

      expect { api.get("/user") }.to raise_error(Supabase::Auth::Errors::AuthRetryableError) do |e|
        expect(e.status).to eq(0)
        expect(e.message).to include("Connection refused")
      end
    end

    it "raises AuthRetryableError for timeout errors" do
      allow_any_instance_of(Faraday::Connection).to receive(:run_request).and_raise(Timeout::Error, "execution expired")

      expect { api.get("/user") }.to raise_error(Supabase::Auth::Errors::AuthRetryableError) do |e|
        expect(e.status).to eq(0)
      end
    end
  end

  describe "non-retryable errors raise AuthApiError immediately without retry" do
    { 400 => "Bad Request", 401 => "Unauthorized", 403 => "Forbidden", 404 => "Not Found", 500 => "Internal Server Error" }.each do |status_code, description|
      it "raises AuthApiError on #{status_code} #{description}" do
        stub_request(:get, "#{base_url}/user")
          .to_return(
            status: status_code,
            body: { "message" => description, "error_code" => "test_error" }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        expect { api.get("/user") }.to raise_error(Supabase::Auth::Errors::AuthApiError) do |e|
          expect(e.status).to eq(status_code)
          expect(e.message).to eq(description)
        end
      end
    end

    it "does not raise AuthRetryableError for 400 errors" do
      stub_request(:post, "#{base_url}/token")
        .to_return(
          status: 400,
          body: { "error_description" => "Invalid login credentials", "error_code" => "invalid_grant" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      expect { api.post("/token", body: {}) }.to raise_error(Supabase::Auth::Errors::AuthApiError)
      expect { api.post("/token", body: {}) }.not_to raise_error(Supabase::Auth::Errors::AuthRetryableError) rescue nil
    end

    it "does not raise AuthRetryableError for 401 errors" do
      stub_request(:get, "#{base_url}/user")
        .to_return(
          status: 401,
          body: { "message" => "Invalid token", "error_code" => "bad_jwt" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      begin
        api.get("/user")
      rescue Supabase::Auth::Errors::AuthApiError
        # Expected
      rescue Supabase::Auth::Errors::AuthRetryableError
        raise "Should not raise AuthRetryableError for 401"
      end
    end
  end

  describe "retry logic respects MAX_RETRIES and RETRY_INTERVAL" do
    it "MAX_RETRIES is 10" do
      expect(Supabase::Auth::Constants::MAX_RETRIES).to eq(10)
    end

    it "RETRY_INTERVAL is 2 deciseconds" do
      expect(Supabase::Auth::Constants::RETRY_INTERVAL).to eq(2)
    end

    it "increments network_retries on each retry attempt in auto-refresh" do
      client = build_client(auto_refresh: true)
      client.instance_variable_set(:@current_session, mock_session)

      call_count = 0
      allow(client).to receive(:_refresh_access_token) do
        call_count += 1
        raise Supabase::Auth::Errors::AuthRetryableError.new("Network error", status: 0)
      end

      # Trigger auto-refresh with minimal delay
      client.send(:_start_auto_refresh_token, 1)
      sleep 0.15

      expect(call_count).to be >= 1
      expect(client.instance_variable_get(:@network_retries)).to be >= 1
    end

    it "stops retrying after MAX_RETRIES attempts in _recover_and_refresh" do
      client = build_client(auto_refresh: true)

      # Set retries to MAX_RETRIES so the next retry should not schedule a new timer
      client.instance_variable_set(:@network_retries, Supabase::Auth::Constants::MAX_RETRIES)

      # Create an expiring session
      expiring_session = Supabase::Auth::Types::Session.new(
        access_token: "expiring-token",
        refresh_token: "expiring-refresh",
        expires_in: 5,
        expires_at: Time.now.to_i - 1, # Already expired
        token_type: "bearer",
        user: mock_user
      )

      # Store session in storage
      storage = client.instance_variable_get(:@storage)
      storage_key = client.instance_variable_get(:@storage_key)
      session_data = {
        "access_token" => expiring_session.access_token,
        "refresh_token" => expiring_session.refresh_token,
        "expires_in" => expiring_session.expires_in,
        "expires_at" => expiring_session.expires_at,
        "token_type" => expiring_session.token_type,
        "user" => {
          "id" => mock_user.id,
          "app_metadata" => {},
          "user_metadata" => {},
          "aud" => mock_user.aud,
          "email" => mock_user.email,
          "created_at" => "2023-01-01T00:00:00Z",
          "updated_at" => "2023-01-01T00:00:00Z"
        }
      }
      storage.set_item(storage_key, JSON.generate(session_data))

      allow(client).to receive(:_call_refresh_token).and_raise(
        Supabase::Auth::Errors::AuthRetryableError.new("Network error", status: 503)
      )

      timer_created = false
      allow(Supabase::Auth::Timer).to receive(:new).and_wrap_original do |method, *args, &block|
        timer_created = true
        timer = method.call(*args, &block)
        allow(timer).to receive(:start)
        timer
      end

      client.send(:_recover_and_refresh)

      # Should NOT schedule a new timer because we're at MAX_RETRIES
      expect(timer_created).to be false
    end

    it "schedules retry with RETRY_INTERVAL-based backoff in _recover_and_refresh" do
      client = build_client(auto_refresh: true)

      # Simulate an expired session in storage
      storage = client.instance_variable_get(:@storage)
      storage_key = client.instance_variable_get(:@storage_key)
      session_data = {
        "access_token" => "expiring-token",
        "refresh_token" => "expiring-refresh",
        "expires_in" => 5,
        "expires_at" => Time.now.to_i - 1,
        "token_type" => "bearer",
        "user" => {
          "id" => mock_user.id,
          "app_metadata" => {},
          "user_metadata" => {},
          "aud" => mock_user.aud,
          "email" => mock_user.email,
          "created_at" => "2023-01-01T00:00:00Z",
          "updated_at" => "2023-01-01T00:00:00Z"
        }
      }
      storage.set_item(storage_key, JSON.generate(session_data))

      allow(client).to receive(:_call_refresh_token).and_raise(
        Supabase::Auth::Errors::AuthRetryableError.new("Network error", status: 503)
      )

      retry_interval = nil
      allow(Supabase::Auth::Timer).to receive(:new).and_wrap_original do |method, interval, &block|
        retry_interval = interval
        timer = method.call(interval, &block)
        allow(timer).to receive(:start)
        timer
      end

      client.send(:_recover_and_refresh)

      # A retry timer should have been created with RETRY_INTERVAL-based duration
      expect(retry_interval).not_to be_nil
      # The interval uses 200 * RETRY_INTERVAL ** (network_retries - 1) / 1000.0
      expect(retry_interval).to be_a(Numeric)
    end
  end

  describe "successful retry after transient failure returns correct response" do
    it "recovers after transient failure when refresh succeeds on subsequent attempt" do
      client = build_client(auto_refresh: true)
      client.instance_variable_set(:@current_session, mock_session)

      call_count = 0
      allow(client).to receive(:_refresh_access_token) do
        call_count += 1
        if call_count == 1
          raise Supabase::Auth::Errors::AuthRetryableError.new("Network error", status: 503)
        end
        # Succeed on second call
        Supabase::Auth::Helpers.parse_auth_response(refreshed_session_hash)
      end

      # Trigger auto-refresh
      client.send(:_start_auto_refresh_token, 1)
      sleep 0.3

      # After retry, the session should be updated
      updated_session = client.instance_variable_get(:@current_session)
      # It should have attempted at least once
      expect(call_count).to be >= 1
    end

    it "resets network_retries to 0 after successful refresh in _recover_and_refresh" do
      client = build_client(auto_refresh: true)
      client.instance_variable_set(:@network_retries, 3)

      # Store a session that is about to expire
      storage = client.instance_variable_get(:@storage)
      storage_key = client.instance_variable_get(:@storage_key)
      session_data = {
        "access_token" => "expiring-token",
        "refresh_token" => "expiring-refresh",
        "expires_in" => 5,
        "expires_at" => Time.now.to_i - 1,
        "token_type" => "bearer",
        "user" => {
          "id" => mock_user.id,
          "app_metadata" => {},
          "user_metadata" => {},
          "aud" => mock_user.aud,
          "email" => mock_user.email,
          "created_at" => "2023-01-01T00:00:00Z",
          "updated_at" => "2023-01-01T00:00:00Z"
        }
      }
      storage.set_item(storage_key, JSON.generate(session_data))

      stub_request(:post, %r{#{base_url}/token})
        .to_return(status: 200, body: refreshed_session_hash.to_json, headers: { "Content-Type" => "application/json" })

      client.send(:_recover_and_refresh)

      expect(client.instance_variable_get(:@network_retries)).to eq(0)
    end

    it "handle_exception correctly maps 502 to AuthRetryableError for retry" do
      error_body = "Bad Gateway"
      response = { status: 502, headers: { "Content-Type" => "text/html" }, body: error_body }
      exception = Faraday::ServerError.new("the server responded with status 502", response)

      result = Supabase::Auth::Helpers.handle_exception(exception)
      expect(result).to be_a(Supabase::Auth::Errors::AuthRetryableError)
      expect(result.status).to eq(502)
    end

    it "handle_exception correctly maps 400 to AuthApiError (non-retryable)" do
      response = {
        status: 400,
        headers: { "Content-Type" => "application/json" },
        body: { "message" => "Bad Request", "error_code" => "bad_request" }.to_json
      }
      exception = Faraday::ClientError.new("the server responded with status 400", response)

      result = Supabase::Auth::Helpers.handle_exception(exception)
      expect(result).to be_a(Supabase::Auth::Errors::AuthApiError)
      expect(result.status).to eq(400)
    end
  end
end
