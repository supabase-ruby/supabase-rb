# frozen_string_literal: true

require "spec_helper"
require "json"
require "faraday"
require "openssl"
require "base64"
require "jwt"

RSpec.describe "US-011: Audit JWT Claims & JWKS" do
  let(:base_url) { "http://localhost:9999" }
  let(:default_headers) { { "apikey" => "test-key" } }

  # Generate an RSA key pair for testing asymmetric JWTs
  let(:rsa_key) { OpenSSL::PKey::RSA.generate(2048) }
  let(:kid) { "test-kid-123" }

  # Build a JWK from the RSA public key (string keys to match JWKS JSON format)
  def build_jwk(rsa_key, kid)
    jwk = JWT::JWK.new(rsa_key, kid: kid)
    jwk.export(include_private: false).transform_keys(&:to_s)
  end

  # Build a signed JWT with given header and payload
  def build_jwt(payload, key, alg: "RS256", kid: nil)
    header = { "alg" => alg, "typ" => "JWT" }
    header["kid"] = kid if kid

    header_b64 = Base64.urlsafe_encode64(header.to_json, padding: false)
    payload_b64 = Base64.urlsafe_encode64(payload.to_json, padding: false)
    signing_input = "#{header_b64}.#{payload_b64}"

    case alg
    when "RS256"
      sig = key.sign("SHA256", signing_input)
    when "HS256"
      sig = OpenSSL::HMAC.digest("SHA256", key, signing_input)
    else
      raise "Unsupported alg in test helper: #{alg}"
    end

    sig_b64 = Base64.urlsafe_encode64(sig, padding: false)
    "#{header_b64}.#{payload_b64}.#{sig_b64}"
  end

  def build_client_with_stubs(flow_type: "implicit", &block)
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

  describe "AC-1: get_claims supports both symmetric (HS256) and asymmetric (RS256, ES256, PS256+) verification" do
    it "handles asymmetric RS256 JWTs via JWKS verification" do
      payload = { "sub" => "user-1", "exp" => Time.now.to_i + 3600, "iat" => Time.now.to_i }
      token = build_jwt(payload, rsa_key, alg: "RS256", kid: kid)
      jwk_hash = build_jwk(rsa_key, kid)

      client, stubs = build_client_with_stubs do |stub|
        stub.get("/.well-known/jwks.json") do
          [200, { "Content-Type" => "application/json" }, { "keys" => [jwk_hash] }.to_json]
        end
      end

      result = client.get_claims(jwt: token)
      expect(result).to be_a(Supabase::Auth::Types::ClaimsResponse)
      expect(result.claims["sub"]).to eq("user-1")
      expect(result.headers["alg"]).to eq("RS256")
      expect(result.headers["kid"]).to eq(kid)
      expect(result.signature).to be_a(String)
    end

    it "handles symmetric HS256 JWTs by falling back to get_user" do
      payload = { "sub" => "user-2", "exp" => Time.now.to_i + 3600, "iat" => Time.now.to_i }
      token = build_jwt(payload, "my-secret-key", alg: "HS256")

      user_data = {
        "id" => "user-2", "aud" => "authenticated", "role" => "authenticated",
        "email" => "test@example.com", "created_at" => "2024-01-01T00:00:00Z",
        "updated_at" => "2024-01-01T00:00:00Z"
      }

      client, stubs = build_client_with_stubs do |stub|
        stub.get("/user") do
          [200, { "Content-Type" => "application/json" }, user_data.to_json]
        end
      end

      result = client.get_claims(jwt: token)
      expect(result).to be_a(Supabase::Auth::Types::ClaimsResponse)
      expect(result.claims["sub"]).to eq("user-2")
      expect(result.headers["alg"]).to eq("HS256")
    end

    it "ALG_TO_DIGEST covers RS256/384/512, ES256/384/512, PS256/384/512" do
      alg_map = Supabase::Auth::Client::ALG_TO_DIGEST
      expect(alg_map).to eq({
        "RS256" => "SHA256", "RS384" => "SHA384", "RS512" => "SHA512",
        "ES256" => "SHA256", "ES384" => "SHA384", "ES512" => "SHA512",
        "PS256" => "SHA256", "PS384" => "SHA384", "PS512" => "SHA512"
      })
    end

    it "ALG_TO_DIGEST is frozen (immutable)" do
      expect(Supabase::Auth::Client::ALG_TO_DIGEST).to be_frozen
    end

    it "raises AuthInvalidJwtError for unsupported algorithms" do
      # Create a JWT with an unsupported algorithm header
      header = { "alg" => "UNSUPPORTED", "typ" => "JWT", "kid" => kid }
      payload = { "sub" => "user-1", "exp" => Time.now.to_i + 3600 }
      header_b64 = Base64.urlsafe_encode64(header.to_json, padding: false)
      payload_b64 = Base64.urlsafe_encode64(payload.to_json, padding: false)
      sig_b64 = Base64.urlsafe_encode64("fake-sig", padding: false)
      token = "#{header_b64}.#{payload_b64}.#{sig_b64}"

      jwk_hash = build_jwk(rsa_key, kid)
      client, stubs = build_client_with_stubs do |stub|
        stub.get("/.well-known/jwks.json") do
          [200, { "Content-Type" => "application/json" }, { "keys" => [jwk_hash] }.to_json]
        end
      end

      expect { client.get_claims(jwt: token) }.to raise_error(
        Supabase::Auth::Errors::AuthInvalidJwtError, /Unsupported algorithm/
      )
    end
  end

  describe "AC-2: Symmetric JWTs validated by calling get_user(token) as fallback" do
    it "calls get_user with the token for HS256 JWTs" do
      payload = { "sub" => "user-3", "exp" => Time.now.to_i + 3600 }
      token = build_jwt(payload, "secret", alg: "HS256")
      get_user_called = false

      client, stubs = build_client_with_stubs do |stub|
        stub.get("/user") do
          get_user_called = true
          [200, { "Content-Type" => "application/json" }, {
            "id" => "user-3", "aud" => "authenticated", "role" => "authenticated",
            "email" => "test@test.com", "created_at" => "2024-01-01T00:00:00Z",
            "updated_at" => "2024-01-01T00:00:00Z"
          }.to_json]
        end
      end

      client.get_claims(jwt: token)
      expect(get_user_called).to be true
    end

    it "calls get_user for JWTs without kid header (matching Python: 'kid' not in header)" do
      # Build JWT without kid
      payload = { "sub" => "user-4", "exp" => Time.now.to_i + 3600 }
      header = { "alg" => "RS256", "typ" => "JWT" } # no kid
      header_b64 = Base64.urlsafe_encode64(header.to_json, padding: false)
      payload_b64 = Base64.urlsafe_encode64(payload.to_json, padding: false)
      sig = rsa_key.sign("SHA256", "#{header_b64}.#{payload_b64}")
      sig_b64 = Base64.urlsafe_encode64(sig, padding: false)
      token = "#{header_b64}.#{payload_b64}.#{sig_b64}"

      get_user_called = false
      client, stubs = build_client_with_stubs do |stub|
        stub.get("/user") do
          get_user_called = true
          [200, { "Content-Type" => "application/json" }, {
            "id" => "user-4", "aud" => "authenticated", "role" => "authenticated",
            "email" => "test@test.com", "created_at" => "2024-01-01T00:00:00Z",
            "updated_at" => "2024-01-01T00:00:00Z"
          }.to_json]
        end
      end

      result = client.get_claims(jwt: token)
      expect(get_user_called).to be true
      expect(result.claims["sub"]).to eq("user-4")
    end
  end

  describe "AC-3: JWKS fetched from /.well-known/jwks.json endpoint" do
    it "fetches JWKS from well-known endpoint for asymmetric JWTs" do
      payload = { "sub" => "user-5", "exp" => Time.now.to_i + 3600 }
      token = build_jwt(payload, rsa_key, alg: "RS256", kid: kid)
      jwk_hash = build_jwk(rsa_key, kid)

      jwks_fetched = false
      client, stubs = build_client_with_stubs do |stub|
        stub.get("/.well-known/jwks.json") do
          jwks_fetched = true
          [200, { "Content-Type" => "application/json" }, { "keys" => [jwk_hash] }.to_json]
        end
      end

      client.get_claims(jwt: token)
      expect(jwks_fetched).to be true
    end

    it "uses supplied jwks parameter before fetching from endpoint" do
      payload = { "sub" => "user-6", "exp" => Time.now.to_i + 3600 }
      token = build_jwt(payload, rsa_key, alg: "RS256", kid: kid)
      jwk_hash = build_jwk(rsa_key, kid)

      jwks_fetched = false
      client, stubs = build_client_with_stubs do |stub|
        stub.get("/.well-known/jwks.json") do
          jwks_fetched = true
          [200, { "Content-Type" => "application/json" }, { "keys" => [jwk_hash] }.to_json]
        end
      end

      # Pass jwks directly — should use these instead of fetching
      result = client.get_claims(jwt: token, jwks: { "keys" => [jwk_hash] })
      expect(jwks_fetched).to be false # should NOT have fetched from endpoint
      expect(result.claims["sub"]).to eq("user-6")
    end

    it "parse_jwks raises AuthInvalidJwtError for empty JWKS" do
      expect {
        Supabase::Auth::Helpers.parse_jwks({ "keys" => [] })
      }.to raise_error(Supabase::Auth::Errors::AuthInvalidJwtError, "JWKS is empty")
    end

    it "parse_jwks raises AuthInvalidJwtError for missing keys field" do
      expect {
        Supabase::Auth::Helpers.parse_jwks({})
      }.to raise_error(Supabase::Auth::Errors::AuthInvalidJwtError, "JWKS is empty")
    end

    it "parse_jwks returns hash with keys array for valid response" do
      result = Supabase::Auth::Helpers.parse_jwks({ "keys" => [{ "kid" => "k1" }] })
      expect(result).to eq({ "keys" => [{ "kid" => "k1" }] })
    end
  end

  describe "AC-4: JWKS cached for 10 minutes (JWKS_TTL = 600 seconds)" do
    it "JWKS_TTL constant is 600 (matching Python's _jwks_ttl = 600)" do
      expect(Supabase::Auth::Client::JWKS_TTL).to eq(600)
    end

    it "caches JWKS and reuses on second call within TTL" do
      payload = { "sub" => "user-7", "exp" => Time.now.to_i + 3600 }
      token = build_jwt(payload, rsa_key, alg: "RS256", kid: kid)
      jwk_hash = build_jwk(rsa_key, kid)

      fetch_count = 0
      client, stubs = build_client_with_stubs do |stub|
        stub.get("/.well-known/jwks.json") do
          fetch_count += 1
          [200, { "Content-Type" => "application/json" }, { "keys" => [jwk_hash] }.to_json]
        end
      end

      # First call should fetch
      client.get_claims(jwt: token)
      expect(fetch_count).to eq(1)

      # Second call should use cache
      client.get_claims(jwt: token)
      expect(fetch_count).to eq(1)
    end

    it "re-fetches JWKS after TTL expires" do
      payload = { "sub" => "user-8", "exp" => Time.now.to_i + 3600 }
      token = build_jwt(payload, rsa_key, alg: "RS256", kid: kid)
      jwk_hash = build_jwk(rsa_key, kid)

      fetch_count = 0
      client, stubs = build_client_with_stubs do |stub|
        stub.get("/.well-known/jwks.json") do
          fetch_count += 1
          [200, { "Content-Type" => "application/json" }, { "keys" => [jwk_hash] }.to_json]
        end
      end

      # First call - fetches
      client.get_claims(jwt: token)
      expect(fetch_count).to eq(1)

      # Expire the cache by backdating @jwks_cached_at
      client.instance_variable_set(:@jwks_cached_at, Time.now.to_f - 601)

      # Should re-fetch
      client.get_claims(jwt: token)
      expect(fetch_count).to eq(2)
    end

    it "initializes JWKS cache as empty (matching Python: {'keys': []})" do
      client, _stubs = build_client_with_stubs
      jwks = client.send(:_jwks)
      expect(jwks).to eq({ "keys" => [] })
    end

    it "initializes JWKS cached_at as nil (matching Python: None)" do
      client, _stubs = build_client_with_stubs
      cached_at = client.instance_variable_get(:@jwks_cached_at)
      expect(cached_at).to be_nil
    end
  end

  describe "AC-5: JWT expiration validated correctly" do
    it "raises AuthInvalidJwtError for expired JWT" do
      payload = { "sub" => "user-9", "exp" => Time.now.to_i - 100 }
      token = build_jwt(payload, rsa_key, alg: "RS256", kid: kid)

      client, _stubs = build_client_with_stubs
      expect { client.get_claims(jwt: token) }.to raise_error(
        Supabase::Auth::Errors::AuthInvalidJwtError, "JWT has expired"
      )
    end

    it "raises AuthInvalidJwtError for nil exp" do
      expect {
        Supabase::Auth::Helpers.validate_exp(nil)
      }.to raise_error(Supabase::Auth::Errors::AuthInvalidJwtError, "JWT has no expiration time")
    end

    it "raises AuthInvalidJwtError for zero exp" do
      expect {
        Supabase::Auth::Helpers.validate_exp(0)
      }.to raise_error(Supabase::Auth::Errors::AuthInvalidJwtError, "JWT has no expiration time")
    end

    it "does not raise for valid future exp" do
      expect { Supabase::Auth::Helpers.validate_exp(Time.now.to_i + 3600) }.not_to raise_error
    end
  end

  describe "AC-6: Algorithm-to-digest mapping covers all supported algorithms" do
    it "covers all 9 asymmetric algorithms matching Python's get_algorithm_by_name support" do
      alg_map = Supabase::Auth::Client::ALG_TO_DIGEST

      # RS family
      expect(alg_map["RS256"]).to eq("SHA256")
      expect(alg_map["RS384"]).to eq("SHA384")
      expect(alg_map["RS512"]).to eq("SHA512")

      # ES family
      expect(alg_map["ES256"]).to eq("SHA256")
      expect(alg_map["ES384"]).to eq("SHA384")
      expect(alg_map["ES512"]).to eq("SHA512")

      # PS family
      expect(alg_map["PS256"]).to eq("SHA256")
      expect(alg_map["PS384"]).to eq("SHA384")
      expect(alg_map["PS512"]).to eq("SHA512")
    end

    it "does not include HS256 (symmetric algorithms handled separately)" do
      expect(Supabase::Auth::Client::ALG_TO_DIGEST).not_to have_key("HS256")
    end

    it "has exactly 9 entries" do
      expect(Supabase::Auth::Client::ALG_TO_DIGEST.size).to eq(9)
    end
  end

  describe "AC-7: ClaimsResponse includes claims, header, and signature fields" do
    it "ClaimsResponse has claims, headers, and signature members" do
      members = Supabase::Auth::Types::ClaimsResponse.members
      expect(members).to contain_exactly(:claims, :headers, :signature)
    end

    it "ClaimsResponse can be constructed with keyword arguments" do
      resp = Supabase::Auth::Types::ClaimsResponse.new(
        claims: { "sub" => "user-10" },
        headers: { "alg" => "RS256" },
        signature: "sig-bytes"
      )
      expect(resp.claims).to eq({ "sub" => "user-10" })
      expect(resp.headers).to eq({ "alg" => "RS256" })
      expect(resp.signature).to eq("sig-bytes")
    end

    it "get_claims returns nil when no session exists and no jwt provided" do
      client, _stubs = build_client_with_stubs
      result = client.get_claims
      expect(result).to be_nil
    end

    it "get_claims uses session access_token when jwt not provided" do
      payload = { "sub" => "session-user", "exp" => Time.now.to_i + 3600 }
      token = build_jwt(payload, "secret", alg: "HS256")

      user_data = {
        "id" => "session-user", "aud" => "authenticated", "role" => "authenticated",
        "email" => "test@test.com", "created_at" => "2024-01-01T00:00:00Z",
        "updated_at" => "2024-01-01T00:00:00Z"
      }

      client, stubs = build_client_with_stubs do |stub|
        stub.get("/user") do
          [200, { "Content-Type" => "application/json" }, user_data.to_json]
        end
      end

      # Store session in storage (persist_session is true by default)
      session_data = {
        "access_token" => token,
        "refresh_token" => "refresh-token",
        "token_type" => "bearer",
        "expires_in" => 3600,
        "expires_at" => Time.now.to_i + 3600
      }
      storage = client.instance_variable_get(:@storage)
      storage.set_item(Supabase::Auth::Client::STORAGE_KEY, session_data.to_json)

      result = client.get_claims
      expect(result).to be_a(Supabase::Auth::Types::ClaimsResponse)
      expect(result.claims["sub"]).to eq("session-user")
    end
  end

  describe "Additional: _fetch_jwks matching Python's _fetch_jwks" do
    it "raises AuthInvalidJwtError when no matching kid in JWKS response" do
      payload = { "sub" => "user-11", "exp" => Time.now.to_i + 3600 }
      token = build_jwt(payload, rsa_key, alg: "RS256", kid: "non-existent-kid")
      jwk_hash = build_jwk(rsa_key, kid) # kid = "test-kid-123", not "non-existent-kid"

      client, stubs = build_client_with_stubs do |stub|
        stub.get("/.well-known/jwks.json") do
          [200, { "Content-Type" => "application/json" }, { "keys" => [jwk_hash] }.to_json]
        end
      end

      expect { client.get_claims(jwt: token) }.to raise_error(
        Supabase::Auth::Errors::AuthInvalidJwtError, "No matching signing key found in JWKS"
      )
    end

    it "raises AuthInvalidJwtError for invalid JWT signature" do
      # Build a JWT signed with one key, but provide JWKS with a different key
      other_key = OpenSSL::PKey::RSA.generate(2048)
      payload = { "sub" => "user-12", "exp" => Time.now.to_i + 3600 }
      token = build_jwt(payload, other_key, alg: "RS256", kid: kid) # signed with other_key
      jwk_hash = build_jwk(rsa_key, kid) # JWKS has rsa_key (different)

      client, stubs = build_client_with_stubs do |stub|
        stub.get("/.well-known/jwks.json") do
          [200, { "Content-Type" => "application/json" }, { "keys" => [jwk_hash] }.to_json]
        end
      end

      expect { client.get_claims(jwt: token) }.to raise_error(
        Supabase::Auth::Errors::AuthInvalidJwtError, "Invalid JWT signature"
      )
    end

    it "decode_jwt raises AuthInvalidJwtError for malformed JWT" do
      expect {
        Supabase::Auth::Helpers.decode_jwt("not.a.valid-jwt!!!")
      }.to raise_error(Supabase::Auth::Errors::AuthInvalidJwtError)
    end

    it "decode_jwt raises AuthInvalidJwtError for JWT with wrong number of parts" do
      expect {
        Supabase::Auth::Helpers.decode_jwt("only.two")
      }.to raise_error(Supabase::Auth::Errors::AuthInvalidJwtError, "Invalid JWT structure")
    end

    it "decode_jwt correctly splits JWT into header, payload, signature, and raw components" do
      payload = { "sub" => "user-13", "exp" => Time.now.to_i + 3600 }
      token = build_jwt(payload, rsa_key, alg: "RS256", kid: kid)

      decoded = Supabase::Auth::Helpers.decode_jwt(token)
      expect(decoded).to have_key(:header)
      expect(decoded).to have_key(:payload)
      expect(decoded).to have_key(:signature)
      expect(decoded).to have_key(:raw)
      expect(decoded[:raw]).to have_key("header")
      expect(decoded[:raw]).to have_key("payload")
      expect(decoded[:header]["alg"]).to eq("RS256")
      expect(decoded[:payload]["sub"]).to eq("user-13")
    end

    it "defaults jwks parameter to empty keys when nil (matching Python: jwks or {'keys': []})" do
      payload = { "sub" => "user-14", "exp" => Time.now.to_i + 3600 }
      token = build_jwt(payload, rsa_key, alg: "RS256", kid: kid)
      jwk_hash = build_jwk(rsa_key, kid)

      client, stubs = build_client_with_stubs do |stub|
        stub.get("/.well-known/jwks.json") do
          [200, { "Content-Type" => "application/json" }, { "keys" => [jwk_hash] }.to_json]
        end
      end

      # Not passing jwks — should default to empty and fetch from endpoint
      result = client.get_claims(jwt: token)
      expect(result.claims["sub"]).to eq("user-14")
    end
  end
end
