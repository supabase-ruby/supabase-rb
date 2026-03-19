# frozen_string_literal: true

require "spec_helper"
require "json"
require "faraday"
require "digest"
require "base64"

RSpec.describe "US-010: Audit PKCE Flow" do
  let(:base_url) { "http://localhost:9999" }
  let(:default_headers) { { "apikey" => "test-key" } }

  # Build a client with Faraday stubs for HTTP testing
  def build_client_with_stubs(flow_type: "pkce", &block)
    stubs = Faraday::Adapter::Test::Stubs.new(&block)
    conn = Faraday.new(url: base_url) do |f|
      f.response :raise_error
      f.adapter :test, stubs
    end
    client = Supabase::Auth::Client.new(
      url: base_url,
      headers: default_headers,
      flow_type: flow_type,
      http_client: conn
    )
    [client, stubs]
  end

  describe "AC-1: Code verifier generation produces cryptographically random values" do
    it "generates a verifier of default length 64" do
      verifier = Supabase::Auth::Helpers.generate_pkce_verifier
      expect(verifier.length).to eq(64)
    end

    it "generates a verifier with only RFC 7636 unreserved characters" do
      verifier = Supabase::Auth::Helpers.generate_pkce_verifier
      expect(verifier).to match(/\A[a-zA-Z0-9\-._~]+\z/)
    end

    it "accepts custom length within 43-128 range" do
      verifier = Supabase::Auth::Helpers.generate_pkce_verifier(43)
      expect(verifier.length).to eq(43)

      verifier = Supabase::Auth::Helpers.generate_pkce_verifier(128)
      expect(verifier.length).to eq(128)
    end

    it "raises ArgumentError for length < 43" do
      expect { Supabase::Auth::Helpers.generate_pkce_verifier(42) }.to raise_error(ArgumentError)
    end

    it "raises ArgumentError for length > 128" do
      expect { Supabase::Auth::Helpers.generate_pkce_verifier(129) }.to raise_error(ArgumentError)
    end

    it "generates different values each time (not deterministic)" do
      v1 = Supabase::Auth::Helpers.generate_pkce_verifier
      v2 = Supabase::Auth::Helpers.generate_pkce_verifier
      expect(v1).not_to eq(v2)
    end

    it "uses the same charset as Python: a-z, A-Z, 0-9, -, ., _, ~" do
      charset = Supabase::Auth::Helpers::PKCE_CHARSET
      expect(charset).to include(*("a".."z").to_a)
      expect(charset).to include(*("A".."Z").to_a)
      expect(charset).to include(*("0".."9").to_a)
      expect(charset).to include("-", ".", "_", "~")
      expect(charset.length).to eq(66) # 26+26+10+4
    end
  end

  describe "AC-2: Code challenge uses S256 method (SHA256 + base64url encoding)" do
    it "produces a valid S256 challenge from a known verifier" do
      verifier = "test-verifier-string-for-pkce-validation-with-min-length-of-43!"
      challenge = Supabase::Auth::Helpers.generate_pkce_challenge(verifier)

      # Manually compute expected challenge
      expected = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
      expect(challenge).to eq(expected)
    end

    it "produces base64url encoding without padding" do
      verifier = Supabase::Auth::Helpers.generate_pkce_verifier
      challenge = Supabase::Auth::Helpers.generate_pkce_challenge(verifier)
      expect(challenge).not_to include("=")
      expect(challenge).to match(/\A[a-zA-Z0-9_-]+\z/)
    end

    it "challenge differs from verifier (S256 not plain)" do
      verifier = Supabase::Auth::Helpers.generate_pkce_verifier
      challenge = Supabase::Auth::Helpers.generate_pkce_challenge(verifier)
      expect(challenge).not_to eq(verifier)
    end
  end

  describe "AC-3: Code verifier stored in storage with key {storage_key}-code-verifier" do
    it "stores verifier when flow_type is pkce during OAuth" do
      client, _stubs = build_client_with_stubs(flow_type: "pkce")
      storage = client._storage

      client.sign_in_with_oauth(provider: "github")

      stored = storage.get_item("supabase.auth.token-code-verifier")
      expect(stored).not_to be_nil
      expect(stored.length).to eq(64)
      expect(stored).to match(/\A[a-zA-Z0-9\-._~]+\z/)
    end

    it "does NOT store verifier when flow_type is implicit" do
      client, _stubs = build_client_with_stubs(flow_type: "implicit")
      storage = client._storage

      client.sign_in_with_oauth(provider: "github")

      stored = storage.get_item("supabase.auth.token-code-verifier")
      expect(stored).to be_nil
    end

    it "uses custom storage_key prefix if configured" do
      stubs = Faraday::Adapter::Test::Stubs.new
      conn = Faraday.new(url: base_url) do |f|
        f.response :raise_error
        f.adapter :test, stubs
      end
      client = Supabase::Auth::Client.new(
        url: base_url,
        headers: default_headers,
        flow_type: "pkce",
        storage_key: "custom.key",
        http_client: conn
      )

      client.sign_in_with_oauth(provider: "github")

      storage = client._storage
      expect(storage.get_item("custom.key-code-verifier")).not_to be_nil
      expect(storage.get_item("supabase.auth.token-code-verifier")).to be_nil
    end

    it "includes code_challenge and code_challenge_method=s256 in OAuth URL" do
      client, _stubs = build_client_with_stubs(flow_type: "pkce")

      result = client.sign_in_with_oauth(provider: "github")
      url = result.url
      params = URI.decode_www_form(URI.parse(url).query).to_h

      expect(params).to have_key("code_challenge")
      expect(params["code_challenge_method"]).to eq("s256")
      expect(params["provider"]).to eq("github")
    end
  end

  describe "AC-4: exchange_code_for_session sends correct body" do
    let(:session_response) do
      {
        "access_token" => "access-123",
        "refresh_token" => "refresh-456",
        "expires_in" => 3600,
        "token_type" => "bearer",
        "user" => {
          "id" => "user-id-123",
          "aud" => "authenticated",
          "role" => "authenticated",
          "email" => "test@example.com",
          "created_at" => "2024-01-01T00:00:00Z",
          "updated_at" => "2024-01-01T00:00:00Z"
        }
      }
    end

    it "sends auth_code and code_verifier in body, grant_type=pkce as query param" do
      captured_body = nil
      captured_query = nil

      client, stubs = build_client_with_stubs do |stub|
        stub.post("/token") do |env|
          captured_body = JSON.parse(env.body)
          captured_query = URI.decode_www_form(env.url.query || "").to_h
          [200, { "Content-Type" => "application/json" }, JSON.generate(session_response)]
        end
      end

      client.exchange_code_for_session(auth_code: "my-auth-code", code_verifier: "my-verifier")
      stubs.verify_stubbed_calls

      expect(captured_body["auth_code"]).to eq("my-auth-code")
      expect(captured_body["code_verifier"]).to eq("my-verifier")
      expect(captured_query["grant_type"]).to eq("pkce")
    end

    it "retrieves code_verifier from storage when not in params" do
      captured_body = nil

      client, stubs = build_client_with_stubs do |stub|
        stub.post("/token") do |env|
          captured_body = JSON.parse(env.body)
          [200, { "Content-Type" => "application/json" }, JSON.generate(session_response)]
        end
      end

      # Pre-store verifier
      client._storage.set_item("supabase.auth.token-code-verifier", "stored-verifier")

      client.exchange_code_for_session(auth_code: "my-auth-code")
      stubs.verify_stubbed_calls

      expect(captured_body["code_verifier"]).to eq("stored-verifier")
    end

    it "passes redirect_to as query param when provided" do
      captured_query = nil

      client, stubs = build_client_with_stubs do |stub|
        stub.post("/token") do |env|
          captured_query = URI.decode_www_form(env.url.query || "").to_h
          [200, { "Content-Type" => "application/json" }, JSON.generate(session_response)]
        end
      end

      client.exchange_code_for_session(
        auth_code: "code-123",
        code_verifier: "verifier-123",
        redirect_to: "http://localhost:3000/callback"
      )
      stubs.verify_stubbed_calls

      expect(captured_query["redirect_to"]).to eq("http://localhost:3000/callback")
    end

    it "supports string keys in params (matching Python dict access)" do
      captured_body = nil

      client, stubs = build_client_with_stubs do |stub|
        stub.post("/token") do |env|
          captured_body = JSON.parse(env.body)
          [200, { "Content-Type" => "application/json" }, JSON.generate(session_response)]
        end
      end

      client.exchange_code_for_session("auth_code" => "string-key-code", "code_verifier" => "string-key-verifier")
      stubs.verify_stubbed_calls

      expect(captured_body["auth_code"]).to eq("string-key-code")
      expect(captured_body["code_verifier"]).to eq("string-key-verifier")
    end
  end

  describe "AC-5: Code verifier cleaned up from storage after successful exchange" do
    let(:session_response) do
      {
        "access_token" => "access-123",
        "refresh_token" => "refresh-456",
        "expires_in" => 3600,
        "token_type" => "bearer",
        "user" => {
          "id" => "user-id-123",
          "aud" => "authenticated",
          "role" => "authenticated",
          "email" => "test@example.com",
          "created_at" => "2024-01-01T00:00:00Z",
          "updated_at" => "2024-01-01T00:00:00Z"
        }
      }
    end

    it "removes code_verifier from storage after exchange" do
      client, stubs = build_client_with_stubs do |stub|
        stub.post("/token") do |_env|
          [200, { "Content-Type" => "application/json" }, JSON.generate(session_response)]
        end
      end

      client._storage.set_item("supabase.auth.token-code-verifier", "to-be-removed")

      client.exchange_code_for_session(auth_code: "code-123")
      stubs.verify_stubbed_calls

      expect(client._storage.get_item("supabase.auth.token-code-verifier")).to be_nil
    end

    it "saves session and emits SIGNED_IN after successful exchange" do
      client, stubs = build_client_with_stubs do |stub|
        stub.post("/token") do |_env|
          [200, { "Content-Type" => "application/json" }, JSON.generate(session_response)]
        end
      end

      events = []
      client.on_auth_state_change { |event, session| events << [event, session] }

      response = client.exchange_code_for_session(auth_code: "code-123", code_verifier: "v")
      stubs.verify_stubbed_calls

      expect(response.session).not_to be_nil
      expect(response.session.access_token).to eq("access-123")
      expect(events.length).to eq(1)
      expect(events[0][0]).to eq("SIGNED_IN")
    end
  end

  describe "AC-6: Flow type correctly switches between implicit and pkce" do
    it "defaults to implicit flow type" do
      stubs = Faraday::Adapter::Test::Stubs.new
      conn = Faraday.new(url: base_url) do |f|
        f.adapter :test, stubs
      end
      client = Supabase::Auth::Client.new(url: base_url, headers: default_headers, http_client: conn)
      expect(client._flow_type).to eq("implicit")
    end

    it "can be configured to pkce flow type" do
      client, _stubs = build_client_with_stubs(flow_type: "pkce")
      expect(client._flow_type).to eq("pkce")
    end

    it "implicit flow does not add code_challenge params to OAuth URL" do
      client, _stubs = build_client_with_stubs(flow_type: "implicit")
      result = client.sign_in_with_oauth(provider: "github")
      url = result.url
      params = URI.decode_www_form(URI.parse(url).query).to_h

      expect(params).not_to have_key("code_challenge")
      expect(params).not_to have_key("code_challenge_method")
    end

    it "pkce flow adds code_challenge and code_challenge_method to OAuth URL" do
      client, _stubs = build_client_with_stubs(flow_type: "pkce")
      result = client.sign_in_with_oauth(provider: "github")
      url = result.url
      params = URI.decode_www_form(URI.parse(url).query).to_h

      expect(params).to have_key("code_challenge")
      expect(params["code_challenge_method"]).to eq("s256")
    end

    it "code_challenge in URL matches SHA256 of stored verifier" do
      client, _stubs = build_client_with_stubs(flow_type: "pkce")

      result = client.sign_in_with_oauth(provider: "github")
      url = result.url
      params = URI.decode_www_form(URI.parse(url).query).to_h

      stored_verifier = client._storage.get_item("supabase.auth.token-code-verifier")
      expected_challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(stored_verifier), padding: false)

      expect(params["code_challenge"]).to eq(expected_challenge)
    end

    it "DEFAULT_OPTIONS matches Python defaults" do
      defaults = Supabase::Auth::Client::DEFAULT_OPTIONS
      expect(defaults[:auto_refresh_token]).to be true
      expect(defaults[:persist_session]).to be true
      expect(defaults[:detect_session_in_url]).to be true
      expect(defaults[:flow_type]).to eq("implicit")
    end

    it "STORAGE_KEY matches Python default" do
      expect(Supabase::Auth::Client::STORAGE_KEY).to eq("supabase.auth.token")
    end
  end
end
