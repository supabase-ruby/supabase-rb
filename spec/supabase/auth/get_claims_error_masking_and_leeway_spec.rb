# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"
require "openssl"
require "json"
require "jwt"

# Regression coverage for two get_claims behaviors (see docs/PARITY.md):
#
#   C-Auth-1 — a domain error raised inside a request (e.g. the JWKS xform
#   raising AuthInvalidJwtError on an empty key set) must reach the caller
#   unchanged, not be masked as AuthRetryableError by the blanket rescue in
#   Api#_request.
#
#   C-Auth-2 (py parity) — get_claims validates claims exactly like supabase-py:
#   a manual exp check with NO clock-skew leeway (helpers.py:286-292), and
#   signature-only verification for asymmetric tokens (algorithm.verify,
#   gotrue_client.py:1272-1282) — nbf/iss/aud are NOT validated.
RSpec.describe "Supabase::Auth::Client#get_claims error masking + py-parity claims" do
  let(:url) { "http://localhost:9999" }
  let(:client) { Supabase::Auth::Client.new(url: url, headers: { "apikey" => "test-key" }) }
  let(:kid) { "key-1" }

  describe "C-Auth-1: JWKS errors are not masked as retryable" do
    it "surfaces AuthInvalidJwtError (not AuthRetryableError) when the JWKS is empty" do
      rsa = OpenSSL::PKey::RSA.generate(2048)
      payload = { "sub" => "u1", "exp" => Time.now.to_i + 3600 }
      token = JWT.encode(payload, rsa, "RS256", { "kid" => kid, "typ" => "JWT" })

      # well-known endpoint responds 200 but with no keys → parse_jwks raises
      # AuthInvalidJwtError("JWKS is empty") inside Api#_request's xform.
      stub_request(:get, "#{url}/.well-known/jwks.json")
        .to_return(status: 200, body: JSON.generate("keys" => []),
                   headers: { "Content-Type" => "application/json" })

      expect { client.get_claims(jwt: token) }
        .to raise_error(Supabase::Auth::Errors::AuthInvalidJwtError, /JWKS is empty/)

      # And specifically NOT the masked retryable error.
      expect { client.get_claims(jwt: token) }
        .not_to raise_error(Supabase::Auth::Errors::AuthRetryableError)
    end
  end

  describe "exp validation — py parity, no leeway" do
    let(:secret) { "shared-symmetric-secret" }

    it "rejects a token expired even a few seconds ago (py has no leeway)" do
      token = JWT.encode({ "sub" => "u1", "exp" => Time.now.to_i - 5 }, secret, "HS256")

      expect { client.get_claims(jwt: token) }
        .to raise_error(Supabase::Auth::Errors::AuthInvalidJwtError, /expired/)
    end

    it "rejects a token expired long ago" do
      token = JWT.encode({ "sub" => "u1", "exp" => Time.now.to_i - 60 }, secret, "HS256")

      expect { client.get_claims(jwt: token) }
        .to raise_error(Supabase::Auth::Errors::AuthInvalidJwtError, /expired/)
    end
  end

  describe "asymmetric path — signature-only verification (py parity)" do
    # py's algorithm.verify() checks the signature and nothing else, so a token
    # with a future nbf is accepted as long as exp and the signature are valid.
    it "accepts a valid-signature token with a future nbf" do
      rsa = OpenSSL::PKey::RSA.generate(2048)
      jwk = JWT::JWK.new(rsa, kid: kid)
      jwks = { "keys" => [jwk.export.transform_keys(&:to_s)] }
      payload = {
        "sub" => "u1",
        "exp" => Time.now.to_i + 3600,
        "nbf" => Time.now.to_i + 600
      }
      token = JWT.encode(payload, rsa, "RS256", { "kid" => kid, "typ" => "JWT" })

      result = client.get_claims(jwt: token, jwks: jwks)
      expect(result.claims["sub"]).to eq("u1")
    end

    it "still rejects a tampered signature" do
      rsa = OpenSSL::PKey::RSA.generate(2048)
      other = OpenSSL::PKey::RSA.generate(2048)
      jwk = JWT::JWK.new(rsa, kid: kid)
      jwks = { "keys" => [jwk.export.transform_keys(&:to_s)] }
      token = JWT.encode({ "sub" => "u1", "exp" => Time.now.to_i + 3600 }, other, "RS256",
                         { "kid" => kid, "typ" => "JWT" })

      expect { client.get_claims(jwt: token, jwks: jwks) }
        .to raise_error(Supabase::Auth::Errors::AuthInvalidJwtError, /Invalid JWT signature/)
    end
  end

  describe "Helpers.validate_exp (unit, py parity)" do
    it "raises for an exp a few seconds in the past" do
      expect { Supabase::Auth::Helpers.validate_exp(Time.now.to_f - 5) }
        .to raise_error(Supabase::Auth::Errors::AuthInvalidJwtError, /expired/)
    end

    it "does not raise for a future exp" do
      expect { Supabase::Auth::Helpers.validate_exp(Time.now.to_f + 60) }
        .not_to raise_error
    end

    it "still raises for a missing exp" do
      expect { Supabase::Auth::Helpers.validate_exp(nil) }
        .to raise_error(Supabase::Auth::Errors::AuthInvalidJwtError, /no expiration/)
    end
  end
end
