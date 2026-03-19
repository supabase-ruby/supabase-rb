# frozen_string_literal: true

require "spec_helper"

# US-010: Audit PKCE Flow
# Verifies that the Ruby PKCE implementation matches the Python SDK behavior.
RSpec.describe "PKCE Flow (US-010)" do
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

  let(:mock_auth_data) do
    {
      "access_token" => "mock-access-token",
      "refresh_token" => "mock-refresh-token",
      "expires_in" => 3600,
      "expires_at" => Time.now.to_i + 3600,
      "token_type" => "bearer",
      "user" => {
        "id" => "test-user-id",
        "app_metadata" => {},
        "user_metadata" => {},
        "aud" => "test-aud",
        "email" => "test@example.com",
        "phone" => "",
        "created_at" => "2023-01-01T00:00:00Z",
        "confirmed_at" => "2023-01-01T00:00:00Z",
        "last_sign_in_at" => "2023-01-01T00:00:00Z",
        "role" => "authenticated",
        "updated_at" => "2023-01-01T00:00:00Z"
      }
    }
  end

  let(:client) do
    Supabase::Auth::Client.new(
      url: "http://localhost:9998",
      auto_refresh_token: false,
      persist_session: false
    )
  end

  # Ported from: helpers.py generate_pkce_verifier — uses secrets.choice over
  # string.ascii_letters + string.digits + "-._~" with default length=64
  describe "Code verifier generation" do
    it "produces cryptographically random values of default length 64" do
      verifier = Supabase::Auth::Helpers.generate_pkce_verifier
      expect(verifier.length).to eq(64)
    end

    it "only contains characters from the unreserved charset (RFC 7636 Appendix B)" do
      allowed = /\A[A-Za-z0-9\-._~]+\z/
      10.times do
        verifier = Supabase::Auth::Helpers.generate_pkce_verifier
        expect(verifier).to match(allowed), "verifier '#{verifier}' contains invalid characters"
      end
    end

    it "accepts custom lengths within 43-128 range matching Python" do
      expect(Supabase::Auth::Helpers.generate_pkce_verifier(43).length).to eq(43)
      expect(Supabase::Auth::Helpers.generate_pkce_verifier(128).length).to eq(128)
    end

    it "rejects lengths below 43 matching Python's ValueError" do
      expect { Supabase::Auth::Helpers.generate_pkce_verifier(42) }
        .to raise_error(ArgumentError, /between 43 and 128/)
    end

    it "rejects lengths above 128 matching Python's ValueError" do
      expect { Supabase::Auth::Helpers.generate_pkce_verifier(129) }
        .to raise_error(ArgumentError, /between 43 and 128/)
    end

    it "produces distinct values on each call (randomness)" do
      verifiers = Array.new(5) { Supabase::Auth::Helpers.generate_pkce_verifier }
      expect(verifiers.uniq.length).to eq(5)
    end
  end

  # Ported from: helpers.py generate_pkce_challenge — SHA-256 + base64url (no padding)
  describe "Code challenge computation (S256)" do
    it "produces known SHA-256 base64url output for a known verifier" do
      # Deterministic test: known input → known output
      verifier = "a" * 64
      expected_digest = Digest::SHA256.digest(verifier)
      expected_challenge = Base64.urlsafe_encode64(expected_digest, padding: false)

      challenge = Supabase::Auth::Helpers.generate_pkce_challenge(verifier)
      expect(challenge).to eq(expected_challenge)
    end

    it "produces base64url output without padding" do
      verifier = Supabase::Auth::Helpers.generate_pkce_verifier
      challenge = Supabase::Auth::Helpers.generate_pkce_challenge(verifier)
      expect(challenge).not_to end_with("=")
    end

    it "challenge is always different from verifier (S256 never plain)" do
      verifier = Supabase::Auth::Helpers.generate_pkce_verifier
      challenge = Supabase::Auth::Helpers.generate_pkce_challenge(verifier)
      expect(challenge).not_to eq(verifier)
    end

    it "challenge is exactly 43 chars (256 bits / 6 bits per base64url char)" do
      verifier = Supabase::Auth::Helpers.generate_pkce_verifier
      challenge = Supabase::Auth::Helpers.generate_pkce_challenge(verifier)
      expect(challenge.length).to eq(43)
    end
  end

  # Ported from: _get_url_for_provider stores verifier with key "{storage_key}-code-verifier"
  describe "Code verifier storage" do
    it "stores verifier with key '{storage_key}-code-verifier' during PKCE flow" do
      client._flow_type = "pkce"
      client._get_url_for_provider("http://example.com/authorize", "github", {})

      storage_key = "#{client._storage_key}-code-verifier"
      stored = client._storage.get_item(storage_key)
      expect(stored).not_to be_nil
      expect(stored.length).to eq(64)
    end

    it "does not store verifier during implicit flow" do
      client._flow_type = "implicit"
      client._get_url_for_provider("http://example.com/authorize", "github", {})

      storage_key = "#{client._storage_key}-code-verifier"
      stored = client._storage.get_item(storage_key)
      expect(stored).to be_nil
    end

    it "storage key uses default 'supabase.auth.token' prefix" do
      expect(client._storage_key).to eq("supabase.auth.token")
    end
  end

  # Ported from: exchange_code_for_session sends POST /token?grant_type=pkce
  # with body {auth_code, code_verifier}
  describe "exchange_code_for_session" do
    it "sends POST to 'token' with grant_type=pkce query param" do
      allow(client).to receive(:_request).and_return(mock_auth_data)

      client.exchange_code_for_session(auth_code: "code-123", code_verifier: "verifier-abc")

      expect(client).to have_received(:_request) do |method, path, **kwargs|
        expect(method).to eq("POST")
        expect(path).to eq("token")
        expect(kwargs[:params]).to eq({ "grant_type" => "pkce" })
      end
    end

    it "sends auth_code and code_verifier in request body" do
      allow(client).to receive(:_request).and_return(mock_auth_data)

      client.exchange_code_for_session(auth_code: "code-123", code_verifier: "verifier-abc")

      expect(client).to have_received(:_request) do |_method, _path, **kwargs|
        expect(kwargs[:body][:auth_code]).to eq("code-123")
        expect(kwargs[:body][:code_verifier]).to eq("verifier-abc")
      end
    end

    it "falls back to storage for code_verifier when not provided in params" do
      client._storage.set_item("#{client._storage_key}-code-verifier", "stored-verifier-xyz")
      allow(client).to receive(:_request).and_return(mock_auth_data)

      client.exchange_code_for_session(auth_code: "code-123")

      expect(client).to have_received(:_request) do |_method, _path, **kwargs|
        expect(kwargs[:body][:code_verifier]).to eq("stored-verifier-xyz")
      end
    end

    it "passes redirect_to through to _request" do
      allow(client).to receive(:_request).and_return(mock_auth_data)

      client.exchange_code_for_session(
        auth_code: "code-123",
        code_verifier: "verifier-abc",
        redirect_to: "https://app.example.com/callback"
      )

      expect(client).to have_received(:_request) do |_method, _path, **kwargs|
        expect(kwargs[:redirect_to]).to eq("https://app.example.com/callback")
      end
    end

    it "accepts string keys matching Python's dict access pattern" do
      allow(client).to receive(:_request).and_return(mock_auth_data)

      client.exchange_code_for_session(
        "auth_code" => "code-from-string",
        "code_verifier" => "verifier-from-string"
      )

      expect(client).to have_received(:_request) do |_method, _path, **kwargs|
        expect(kwargs[:body][:auth_code]).to eq("code-from-string")
        expect(kwargs[:body][:code_verifier]).to eq("verifier-from-string")
      end
    end
  end

  # Ported from: code_verifier removed from storage after exchange
  describe "Code verifier cleanup" do
    it "removes code_verifier from storage after successful exchange" do
      storage_key = "#{client._storage_key}-code-verifier"
      client._storage.set_item(storage_key, "verifier-to-clean")
      allow(client).to receive(:_request).and_return(mock_auth_data)

      client.exchange_code_for_session(auth_code: "code-123")

      expect(client._storage.get_item(storage_key)).to be_nil
    end

    it "removes code_verifier even when session is nil (no user returned)" do
      storage_key = "#{client._storage_key}-code-verifier"
      client._storage.set_item(storage_key, "verifier-to-clean")
      no_session_data = mock_auth_data.merge("access_token" => nil, "refresh_token" => nil)
      allow(client).to receive(:_request).and_return(no_session_data)

      client.exchange_code_for_session(auth_code: "code-123")

      expect(client._storage.get_item(storage_key)).to be_nil
    end
  end

  # Ported from: flow_type defaults to "implicit", can be set to "pkce"
  describe "Flow type switching" do
    it "defaults to 'implicit'" do
      default_client = Supabase::Auth::Client.new(
        url: "http://localhost:9998",
        auto_refresh_token: false,
        persist_session: false
      )
      expect(default_client._flow_type).to eq("implicit")
    end

    it "can be set to 'pkce' via constructor" do
      pkce_client = Supabase::Auth::Client.new(
        url: "http://localhost:9998",
        auto_refresh_token: false,
        persist_session: false,
        flow_type: "pkce"
      )
      expect(pkce_client._flow_type).to eq("pkce")
    end

    it "adds code_challenge and code_challenge_method only when flow_type is pkce" do
      client._flow_type = "pkce"
      _url, pkce_params = client._get_url_for_provider("http://example.com/authorize", "github", {})
      expect(pkce_params).to include("code_challenge", "code_challenge_method")

      client._flow_type = "implicit"
      _url, implicit_params = client._get_url_for_provider("http://example.com/authorize", "github", {})
      expect(implicit_params).not_to include("code_challenge")
      expect(implicit_params).not_to include("code_challenge_method")
    end

    it "sets code_challenge_method to 's256' (never 'plain' in practice)" do
      client._flow_type = "pkce"
      _url, params = client._get_url_for_provider("http://example.com/authorize", "github", {})
      expect(params["code_challenge_method"]).to eq("s256")
    end

    it "saves session and emits SIGNED_IN on successful code exchange" do
      allow(client).to receive(:_request).and_return(mock_auth_data)

      events = []
      client.on_auth_state_change { |event, _session| events << event }

      response = client.exchange_code_for_session(
        auth_code: "code-123",
        code_verifier: "verifier-abc"
      )

      expect(response.session).not_to be_nil
      expect(response.session.access_token).to eq("mock-access-token")
      expect(events).to include("SIGNED_IN")
    end
  end
end
