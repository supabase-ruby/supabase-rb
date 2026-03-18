# frozen_string_literal: true

require "webmock/rspec"
require "openssl"
require "base64"
require "json"
require "jwt"

RSpec.describe "JWT Claims & JWKS" do
  let(:url) { "http://localhost:9999" }
  let(:client) { Supabase::Auth::Client.new(url: url, headers: { "apikey" => "test-key" }) }

  # Helper to build a base64url-encoded string
  def base64url_encode(data)
    if data.is_a?(String)
      Base64.urlsafe_encode64(data, padding: false)
    else
      Base64.urlsafe_encode64(JSON.generate(data), padding: false)
    end
  end

  # Build a JWT from parts (unsigned or with custom signature)
  def build_jwt(header, payload, signature_bytes = "\x00")
    [
      base64url_encode(header),
      base64url_encode(payload),
      Base64.urlsafe_encode64(signature_bytes, padding: false)
    ].join(".")
  end

  # Generate an RSA-signed JWT and matching JWKS
  def build_rsa_signed_jwt(payload_data, kid: "test-key-id")
    rsa_key = OpenSSL::PKey::RSA.generate(2048)

    header = { "alg" => "RS256", "typ" => "JWT", "kid" => kid }
    raw_header = base64url_encode(header)
    raw_payload = base64url_encode(payload_data)

    signature = rsa_key.sign("SHA256", "#{raw_header}.#{raw_payload}")
    raw_sig = Base64.urlsafe_encode64(signature, padding: false)

    token = "#{raw_header}.#{raw_payload}.#{raw_sig}"

    jwk = JWT::JWK.new(rsa_key, kid: kid)
    jwks = { "keys" => [jwk.export.transform_keys(&:to_s)] }

    [token, jwks, rsa_key]
  end

  describe "Supabase::Auth::Types::ClaimsResponse" do
    it "is a Struct with claims, headers, and signature fields" do
      response = Supabase::Auth::Types::ClaimsResponse.new(
        claims: { "sub" => "123" },
        headers: { "alg" => "RS256" },
        signature: "\x00"
      )

      expect(response.claims).to eq({ "sub" => "123" })
      expect(response.headers).to eq({ "alg" => "RS256" })
      expect(response.signature).to eq("\x00")
    end
  end

  describe "Helpers.decode_jwt" do
    it "decodes a valid JWT into header, payload, signature, and raw parts" do
      header = { "alg" => "RS256", "typ" => "JWT", "kid" => "key1" }
      payload = { "sub" => "user1", "exp" => (Time.now.to_i + 3600), "iss" => "test" }
      token = build_jwt(header, payload)

      decoded = Supabase::Auth::Helpers.decode_jwt(token)

      expect(decoded[:header]).to eq(header)
      expect(decoded[:payload]).to eq(payload)
      expect(decoded[:signature]).to be_a(String)
      expect(decoded[:raw]["header"]).to be_a(String)
      expect(decoded[:raw]["payload"]).to be_a(String)
    end

    it "raises AuthInvalidJwtError for invalid JWT structure" do
      expect {
        Supabase::Auth::Helpers.decode_jwt("not.a-jwt")
      }.to raise_error(Supabase::Auth::Errors::AuthInvalidJwtError, /Invalid JWT structure/)
    end

    it "raises AuthInvalidJwtError for non-base64url parts" do
      expect {
        Supabase::Auth::Helpers.decode_jwt("abc!.def@.ghi#")
      }.to raise_error(Supabase::Auth::Errors::AuthInvalidJwtError, /base64url/)
    end
  end

  describe "Helpers.validate_exp" do
    it "raises AuthInvalidJwtError for nil expiration" do
      expect {
        Supabase::Auth::Helpers.validate_exp(nil)
      }.to raise_error(Supabase::Auth::Errors::AuthInvalidJwtError, /no expiration/)
    end

    it "raises AuthInvalidJwtError for expired JWT" do
      expect {
        Supabase::Auth::Helpers.validate_exp(Time.now.to_i - 100)
      }.to raise_error(Supabase::Auth::Errors::AuthInvalidJwtError, /expired/)
    end

    it "does not raise for valid future expiration" do
      expect {
        Supabase::Auth::Helpers.validate_exp(Time.now.to_i + 3600)
      }.not_to raise_error
    end
  end

  describe "Helpers.parse_jwks" do
    it "returns keys hash from valid JWKS response" do
      result = Supabase::Auth::Helpers.parse_jwks({ "keys" => [{ "kid" => "k1" }] })
      expect(result).to eq({ "keys" => [{ "kid" => "k1" }] })
    end

    it "raises AuthInvalidJwtError for empty JWKS" do
      expect {
        Supabase::Auth::Helpers.parse_jwks({ "keys" => [] })
      }.to raise_error(Supabase::Auth::Errors::AuthInvalidJwtError, /JWKS is empty/)
    end

    it "raises AuthInvalidJwtError for missing keys field" do
      expect {
        Supabase::Auth::Helpers.parse_jwks({})
      }.to raise_error(Supabase::Auth::Errors::AuthInvalidJwtError, /JWKS is empty/)
    end
  end

  describe "Client#get_claims" do
    it "returns nil when no JWT provided and no session" do
      result = client.get_claims
      expect(result).to be_nil
    end

    context "with symmetric JWT (no kid)" do
      let(:payload_data) do
        { "sub" => "user1", "exp" => (Time.now.to_i + 3600), "iss" => "test", "iat" => Time.now.to_i }
      end
      let(:token) { build_jwt({ "alg" => "HS256", "typ" => "JWT" }, payload_data) }

      it "falls back to get_user for HS256 algorithm" do
        stub_request(:get, "#{url}/user")
          .to_return(
            status: 200,
            body: JSON.generate({ "id" => "user1", "email" => "test@test.com", "aud" => "authenticated", "role" => "authenticated" }),
            headers: { "Content-Type" => "application/json" }
          )

        result = client.get_claims(jwt: token)

        expect(result).to be_a(Supabase::Auth::Types::ClaimsResponse)
        expect(result.claims["sub"]).to eq("user1")
        expect(result.headers["alg"]).to eq("HS256")
        expect(result.signature).to be_a(String)
      end

      it "falls back to get_user when kid is missing" do
        no_kid_token = build_jwt({ "alg" => "RS256", "typ" => "JWT" }, payload_data)

        stub_request(:get, "#{url}/user")
          .to_return(
            status: 200,
            body: JSON.generate({ "id" => "user1", "email" => "test@test.com", "aud" => "authenticated", "role" => "authenticated" }),
            headers: { "Content-Type" => "application/json" }
          )

        result = client.get_claims(jwt: no_kid_token)

        expect(result).to be_a(Supabase::Auth::Types::ClaimsResponse)
        expect(result.claims["sub"]).to eq("user1")
      end
    end

    context "with asymmetric JWT (RS256)" do
      let(:payload_data) do
        { "sub" => "user1", "exp" => (Time.now.to_i + 3600), "iss" => "test", "iat" => Time.now.to_i }
      end

      it "verifies signature via supplied JWKS" do
        token, jwks, = build_rsa_signed_jwt(payload_data)

        result = client.get_claims(jwt: token, jwks: jwks)

        expect(result).to be_a(Supabase::Auth::Types::ClaimsResponse)
        expect(result.claims["sub"]).to eq("user1")
        expect(result.headers["alg"]).to eq("RS256")
        expect(result.headers["kid"]).to eq("test-key-id")
      end

      it "raises AuthInvalidJwtError for expired JWT" do
        expired_payload = payload_data.merge("exp" => Time.now.to_i - 100)
        token, jwks, = build_rsa_signed_jwt(expired_payload)

        expect {
          client.get_claims(jwt: token, jwks: jwks)
        }.to raise_error(Supabase::Auth::Errors::AuthInvalidJwtError, /expired/)
      end

      it "raises AuthInvalidJwtError for invalid signature" do
        token, jwks, = build_rsa_signed_jwt(payload_data)

        # Tamper with the signature by replacing it
        parts = token.split(".")
        parts[2] = Base64.urlsafe_encode64("tampered_signature_data_xxxxx", padding: false)
        tampered_token = parts.join(".")

        expect {
          client.get_claims(jwt: tampered_token, jwks: jwks)
        }.to raise_error(Supabase::Auth::Errors::AuthInvalidJwtError, /Invalid JWT signature/)
      end

      it "raises AuthInvalidJwtError when signed with wrong RSA key" do
        # Sign with one key, provide JWKS from a different key
        wrong_key = OpenSSL::PKey::RSA.generate(2048)
        correct_key = OpenSSL::PKey::RSA.generate(2048)

        header = { "alg" => "RS256", "typ" => "JWT", "kid" => "test-key-id" }
        raw_header = base64url_encode(header)
        raw_payload = base64url_encode(payload_data)
        signature = wrong_key.sign("SHA256", "#{raw_header}.#{raw_payload}")
        raw_sig = Base64.urlsafe_encode64(signature, padding: false)
        token = "#{raw_header}.#{raw_payload}.#{raw_sig}"

        jwk = JWT::JWK.new(correct_key, kid: "test-key-id")
        jwks = { "keys" => [jwk.export.transform_keys(&:to_s)] }

        expect {
          client.get_claims(jwt: token, jwks: jwks)
        }.to raise_error(Supabase::Auth::Errors::AuthInvalidJwtError, /Invalid JWT signature/)
      end

      it "raises AuthInvalidJwtError for unsupported algorithm" do
        rsa_key = OpenSSL::PKey::RSA.generate(2048)
        header = { "alg" => "UNSUPPORTED", "typ" => "JWT", "kid" => "test-key-id" }
        raw_header = base64url_encode(header)
        raw_payload = base64url_encode(payload_data)
        signature = rsa_key.sign("SHA256", "#{raw_header}.#{raw_payload}")
        raw_sig = Base64.urlsafe_encode64(signature, padding: false)
        token = "#{raw_header}.#{raw_payload}.#{raw_sig}"

        jwk = JWT::JWK.new(rsa_key, kid: "test-key-id")
        jwks = { "keys" => [jwk.export.transform_keys(&:to_s)] }

        expect {
          client.get_claims(jwt: token, jwks: jwks)
        }.to raise_error(Supabase::Auth::Errors::AuthInvalidJwtError, /Unsupported algorithm/)
      end
    end

    context "with session access token" do
      let(:non_persist_client) { Supabase::Auth::Client.new(url: url, headers: { "apikey" => "test-key" }, persist_session: false) }

      it "uses session access_token when no JWT parameter given" do
        payload_data = { "sub" => "user1", "exp" => (Time.now.to_i + 3600), "iss" => "test", "iat" => Time.now.to_i }
        token, jwks, = build_rsa_signed_jwt(payload_data)

        session = Supabase::Auth::Types::Session.new(
          access_token: token,
          refresh_token: "refresh",
          expires_in: 3600,
          expires_at: Time.now.to_i + 3600,
          token_type: "bearer"
        )
        non_persist_client.instance_variable_set(:@current_session, session)

        result = non_persist_client.get_claims(jwks: jwks)

        expect(result).to be_a(Supabase::Auth::Types::ClaimsResponse)
        expect(result.claims["sub"]).to eq("user1")
      end
    end
  end

  describe "Client#_fetch_jwks" do
    it "returns key from supplied JWKS when kid matches" do
      jwks = { "keys" => [{ "kid" => "key1", "kty" => "RSA" }] }
      result = client.send(:_fetch_jwks, "key1", jwks)
      expect(result).to eq({ "kid" => "key1", "kty" => "RSA" })
    end

    it "returns key from cache within TTL" do
      cached_jwks = { "keys" => [{ "kid" => "cached-key", "kty" => "RSA" }] }
      client.instance_variable_set(:@jwks, cached_jwks)
      client.instance_variable_set(:@jwks_cached_at, Time.now.to_f)

      result = client.send(:_fetch_jwks, "cached-key", { "keys" => [] })
      expect(result).to eq({ "kid" => "cached-key", "kty" => "RSA" })
    end

    it "does not use cache when TTL has expired" do
      cached_jwks = { "keys" => [{ "kid" => "old-key", "kty" => "RSA" }] }
      client.instance_variable_set(:@jwks, cached_jwks)
      client.instance_variable_set(:@jwks_cached_at, Time.now.to_f - 601) # Past 600s TTL

      fresh_jwks = { "keys" => [{ "kid" => "new-key", "kty" => "RSA" }] }
      stub_request(:get, "#{url}/.well-known/jwks.json")
        .to_return(
          status: 200,
          body: JSON.generate(fresh_jwks),
          headers: { "Content-Type" => "application/json" }
        )

      result = client.send(:_fetch_jwks, "new-key", { "keys" => [] })
      expect(result).to eq({ "kid" => "new-key", "kty" => "RSA" })
    end

    it "fetches from well-known endpoint when key not in cache" do
      remote_jwks = { "keys" => [{ "kid" => "remote-key", "kty" => "RSA" }] }
      stub_request(:get, "#{url}/.well-known/jwks.json")
        .to_return(
          status: 200,
          body: JSON.generate(remote_jwks),
          headers: { "Content-Type" => "application/json" }
        )

      result = client.send(:_fetch_jwks, "remote-key", { "keys" => [] })
      expect(result).to eq({ "kid" => "remote-key", "kty" => "RSA" })
    end

    it "caches fetched JWKS with timestamp" do
      remote_jwks = { "keys" => [{ "kid" => "key1", "kty" => "RSA" }] }
      stub_request(:get, "#{url}/.well-known/jwks.json")
        .to_return(
          status: 200,
          body: JSON.generate(remote_jwks),
          headers: { "Content-Type" => "application/json" }
        )

      before = Time.now.to_f
      client.send(:_fetch_jwks, "key1", { "keys" => [] })
      after = Time.now.to_f

      expect(client.instance_variable_get(:@jwks)).to eq(remote_jwks)
      cached_at = client.instance_variable_get(:@jwks_cached_at)
      expect(cached_at).to be_between(before, after)
    end

    it "raises AuthInvalidJwtError when kid not found in fetched JWKS" do
      remote_jwks = { "keys" => [{ "kid" => "other-key", "kty" => "RSA" }] }
      stub_request(:get, "#{url}/.well-known/jwks.json")
        .to_return(
          status: 200,
          body: JSON.generate(remote_jwks),
          headers: { "Content-Type" => "application/json" }
        )

      expect {
        client.send(:_fetch_jwks, "missing-key", { "keys" => [] })
      }.to raise_error(Supabase::Auth::Errors::AuthInvalidJwtError, /No matching signing key/)
    end
  end

  describe "JWKS TTL constant" do
    it "is set to 600 seconds (10 minutes)" do
      expect(Supabase::Auth::Client::JWKS_TTL).to eq(600)
    end
  end

  describe "ALG_TO_DIGEST mapping" do
    it "covers all supported asymmetric algorithms" do
      expected = {
        "RS256" => "SHA256", "RS384" => "SHA384", "RS512" => "SHA512",
        "ES256" => "SHA256", "ES384" => "SHA384", "ES512" => "SHA512",
        "PS256" => "SHA256", "PS384" => "SHA384", "PS512" => "SHA512"
      }
      expect(Supabase::Auth::Client::ALG_TO_DIGEST).to eq(expected)
    end

    it "is frozen" do
      expect(Supabase::Auth::Client::ALG_TO_DIGEST).to be_frozen
    end
  end
end
