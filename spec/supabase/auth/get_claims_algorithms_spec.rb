# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"
require "openssl"
require "base64"
require "json"
require "jwt"

# Parity story US-001 (PRD: расхождения с supabase-py):
# - `get_claims` принимает тот же набор алгоритмов, что и PyJWT по умолчанию;
# - HS256 / отсутствующий `kid` → fallback на `get_user` (как в py);
# - неизвестный alg → `AuthInvalidJwtError("Algorithm not supported")`.
RSpec.describe "Supabase::Auth::Client#get_claims algorithm parity" do
  let(:url) { "http://localhost:9999" }
  let(:client) { Supabase::Auth::Client.new(url: url, headers: { "apikey" => "test-key" }) }
  let(:kid) { "key-1" }
  let(:payload) do
    { "sub" => "user-1", "exp" => Time.now.to_i + 3600, "iat" => Time.now.to_i, "iss" => "test" }
  end

  def b64(value)
    Base64.urlsafe_encode64(value.is_a?(String) ? value : JSON.generate(value), padding: false)
  end

  # Sign a token using JWT.encode with an explicit kid in the header.
  def encode_with_kid(payload, key, alg)
    JWT.encode(payload, key, alg, { "kid" => kid, "typ" => "JWT" })
  end

  # Build a JWKS hash containing the public part of `key` under our `kid`.
  def jwks_for(key)
    jwk = JWT::JWK.new(key, kid: kid)
    { "keys" => [jwk.export.transform_keys(&:to_s)] }
  end

  describe "SUPPORTED_ALGORITHMS constant" do
    it "covers PyJWT default set: HS/RS/ES/PS families + EdDSA" do
      expect(Supabase::Auth::Client::SUPPORTED_ALGORITHMS).to contain_exactly(
        "HS256", "HS384", "HS512",
        "RS256", "RS384", "RS512",
        "ES256", "ES256K", "ES384", "ES512",
        "PS256", "PS384", "PS512",
        "EdDSA", "Ed25519"
      )
    end

    it "is frozen" do
      expect(Supabase::Auth::Client::SUPPORTED_ALGORITHMS).to be_frozen
    end
  end

  describe "HS256 — поведение совпадает с py (fallback на get_user)" do
    let(:secret) { "shared-symmetric-secret" }

    it "вызывает /user и возвращает ClaimsResponse, не пытаясь дернуть JWKS" do
      token = JWT.encode(payload, secret, "HS256")
      stub_request(:get, "#{url}/user").to_return(
        status: 200,
        body: JSON.generate("id" => "user-1", "aud" => "authenticated", "role" => "authenticated", "email" => "x@x"),
        headers: { "Content-Type" => "application/json" }
      )

      result = client.get_claims(jwt: token)

      expect(result).to be_a(Supabase::Auth::Types::ClaimsResponse)
      expect(result.claims["sub"]).to eq("user-1")
      expect(result.headers["alg"]).to eq("HS256")
      # JWKS не должен запрашиваться, даже если в заголовке указан kid.
      expect(WebMock).not_to have_requested(:get, "#{url}/.well-known/jwks.json")
    end

    it "fallback срабатывает даже когда в заголовке HS256 указан kid (paritет с py)" do
      token = JWT.encode(payload, secret, "HS256", { "kid" => "ignored-kid" })
      stub_request(:get, "#{url}/user").to_return(
        status: 200,
        body: JSON.generate("id" => "user-1", "aud" => "authenticated", "role" => "authenticated", "email" => "x@x"),
        headers: { "Content-Type" => "application/json" }
      )

      result = client.get_claims(jwt: token)
      expect(result.headers["alg"]).to eq("HS256")
      expect(WebMock).not_to have_requested(:get, "#{url}/.well-known/jwks.json")
    end

    it "fallback на /user также при отсутствии kid в заголовке (любой alg)" do
      token = JWT.encode(payload, OpenSSL::PKey::RSA.generate(2048), "RS256")
      stub_request(:get, "#{url}/user").to_return(
        status: 200,
        body: JSON.generate("id" => "user-1", "aud" => "authenticated", "role" => "authenticated", "email" => "x@x"),
        headers: { "Content-Type" => "application/json" }
      )

      result = client.get_claims(jwt: token)
      expect(result.claims["sub"]).to eq("user-1")
    end
  end

  describe "Асимметричные алгоритмы — round-trip с JWKS-фикстурой" do
    {
      "RS256" => -> { OpenSSL::PKey::RSA.generate(2048) },
      "RS384" => -> { OpenSSL::PKey::RSA.generate(2048) },
      "RS512" => -> { OpenSSL::PKey::RSA.generate(2048) },
      "PS256" => -> { OpenSSL::PKey::RSA.generate(2048) },
      "PS384" => -> { OpenSSL::PKey::RSA.generate(2048) },
      "PS512" => -> { OpenSSL::PKey::RSA.generate(2048) },
      "ES256" => -> { OpenSSL::PKey::EC.generate("prime256v1") },
      "ES384" => -> { OpenSSL::PKey::EC.generate("secp384r1") },
      "ES512" => -> { OpenSSL::PKey::EC.generate("secp521r1") }
    }.each do |alg, key_factory|
      it "верифицирует #{alg}-токен через переданный JWKS" do
        key = key_factory.call
        token = encode_with_kid(payload, key, alg)
        jwks = jwks_for(key)

        result = client.get_claims(jwt: token, jwks: jwks)

        expect(result).to be_a(Supabase::Auth::Types::ClaimsResponse)
        expect(result.claims["sub"]).to eq("user-1")
        expect(result.headers["alg"]).to eq(alg)
        expect(result.headers["kid"]).to eq(kid)
      end
    end
  end

  describe "EdDSA — условная поддержка" do
    let(:rbnacl_available?) do
      begin
        require "rbnacl"
        true
      rescue LoadError
        false
      end
    end

    it "EdDSA включён в SUPPORTED_ALGORITHMS (verify требует rbnacl)" do
      expect(Supabase::Auth::Client::SUPPORTED_ALGORITHMS).to include("EdDSA", "Ed25519")
    end

    it "верифицирует Ed25519-токен, если установлен rbnacl" do
      skip "rbnacl не установлен — EdDSA verify невозможна" unless rbnacl_available?

      signing_key = RbNaCl::Signatures::Ed25519::SigningKey.generate
      verify_key  = signing_key.verify_key
      # Use the standard JOSE algorithm name "EdDSA" (RFC 8037) — the value real
      # Supabase tokens and PyJWT use. ruby-jwt's legacy "ED25519" name is
      # deprecated and isn't a real-world `alg` header, so we don't accept it.
      token = JWT.encode(payload, signing_key, "EdDSA", { "kid" => kid, "typ" => "JWT" })

      jwk = JWT::JWK.new(verify_key, kid: kid)
      jwks = { "keys" => [jwk.export.transform_keys(&:to_s)] }

      result = client.get_claims(jwt: token, jwks: jwks)
      expect(result).to be_a(Supabase::Auth::Types::ClaimsResponse)
      expect(result.headers["alg"]).to eq("EdDSA")
    end
  end

  describe "Неизвестный алгоритм" do
    it "бросает AuthInvalidJwtError с сообщением 'Algorithm not supported'" do
      header = { "alg" => "FOO123", "typ" => "JWT", "kid" => kid }
      token = "#{b64(header)}.#{b64(payload)}.#{b64('signature')}"

      expect { client.get_claims(jwt: token, jwks: { "keys" => [{ "kid" => kid }] }) }
        .to raise_error(Supabase::Auth::Errors::AuthInvalidJwtError, "Algorithm not supported")
    end

    it "проверка alg выполняется ДО обращения за JWKS (паритет с py)" do
      header = { "alg" => "BAR456", "typ" => "JWT", "kid" => kid }
      token = "#{b64(header)}.#{b64(payload)}.#{b64('signature')}"

      expect { client.get_claims(jwt: token) }.to raise_error(Supabase::Auth::Errors::AuthInvalidJwtError)
      expect(WebMock).not_to have_requested(:get, "#{url}/.well-known/jwks.json")
    end
  end

  describe "Интеграция: static JWKS-фикстура (RS256 + ES256)" do
    # Тест не ходит в сеть: JWKS передаётся параметром, как сделал бы пользователь,
    # у которого ключи известны заранее.
    it "обслуживает оба алгоритма из одного JWKS-набора" do
      rsa = OpenSSL::PKey::RSA.generate(2048)
      ec  = OpenSSL::PKey::EC.generate("prime256v1")

      rsa_kid = "rs256-key"
      ec_kid  = "es256-key"

      rsa_token = JWT.encode(payload, rsa, "RS256", { "kid" => rsa_kid, "typ" => "JWT" })
      ec_token  = JWT.encode(payload.merge("sub" => "user-ec"), ec, "ES256", { "kid" => ec_kid, "typ" => "JWT" })

      jwks = {
        "keys" => [
          JWT::JWK.new(rsa, kid: rsa_kid).export.transform_keys(&:to_s),
          JWT::JWK.new(ec,  kid: ec_kid ).export.transform_keys(&:to_s)
        ]
      }

      rsa_result = client.get_claims(jwt: rsa_token, jwks: jwks)
      ec_result  = client.get_claims(jwt: ec_token,  jwks: jwks)

      expect(rsa_result.claims["sub"]).to eq("user-1")
      expect(rsa_result.headers["kid"]).to eq(rsa_kid)
      expect(ec_result.claims["sub"]).to eq("user-ec")
      expect(ec_result.headers["kid"]).to eq(ec_kid)
    end
  end
end
