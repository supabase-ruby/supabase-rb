# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"

RSpec.describe Supabase::Auth::Api do
  let(:base_url) { "https://example.supabase.co/auth/v1" }
  let(:default_headers) { { "apikey" => "test-api-key" } }
  let(:api) { described_class.new(url: base_url, headers: default_headers) }

  describe "#initialize" do
    it "stores url and headers" do
      expect(api.url).to eq(base_url)
      expect(api.headers).to eq(default_headers)
    end

    it "accepts a custom http_client" do
      custom_client = Faraday.new(url: base_url)
      api = described_class.new(url: base_url, headers: default_headers, http_client: custom_client)
      expect(api).to be_a(described_class)
    end
  end

  describe "#get" do
    it "sends a GET request and parses JSON response" do
      stub_request(:get, "#{base_url}/user")
        .with(headers: { "apikey" => "test-api-key", "Content-Type" => "application/json;charset=UTF-8" })
        .to_return(status: 200, body: '{"id":"123","email":"test@example.com"}', headers: { "Content-Type" => "application/json" })

      result = api.get("/user")
      expect(result).to eq({ "id" => "123", "email" => "test@example.com" })
    end

    it "sends query parameters" do
      stub_request(:get, "#{base_url}/admin/users")
        .with(query: { "page" => "1", "per_page" => "50" })
        .to_return(status: 200, body: '{"users":[]}', headers: { "Content-Type" => "application/json" })

      result = api.get("/admin/users", params: { "page" => "1", "per_page" => "50" })
      expect(result).to eq({ "users" => [] })
    end

    it "merges additional headers with defaults" do
      stub_request(:get, "#{base_url}/user")
        .with(headers: {
          "apikey" => "test-api-key",
          "Authorization" => "Bearer token123"
        })
        .to_return(status: 200, body: '{}', headers: { "Content-Type" => "application/json" })

      api.get("/user", headers: { "Authorization" => "Bearer token123" })
    end
  end

  describe "#post" do
    it "sends a POST request with JSON body" do
      stub_request(:post, "#{base_url}/signup")
        .with(
          body: '{"email":"test@example.com","password":"secret123"}',
          headers: { "Content-Type" => "application/json;charset=UTF-8", "apikey" => "test-api-key" }
        )
        .to_return(status: 200, body: '{"user":{"id":"123"}}', headers: { "Content-Type" => "application/json" })

      result = api.post("/signup", body: { email: "test@example.com", password: "secret123" })
      expect(result).to eq({ "user" => { "id" => "123" } })
    end

    it "sends query parameters with POST" do
      stub_request(:post, "#{base_url}/token")
        .with(query: { "grant_type" => "password" })
        .to_return(status: 200, body: '{"access_token":"abc"}', headers: { "Content-Type" => "application/json" })

      result = api.post("/token", body: { email: "test@example.com", password: "pass" }, params: { "grant_type" => "password" })
      expect(result).to eq({ "access_token" => "abc" })
    end
  end

  describe "#put" do
    it "sends a PUT request with JSON body" do
      stub_request(:put, "#{base_url}/user")
        .with(
          body: '{"data":{"name":"Updated"}}',
          headers: { "Content-Type" => "application/json;charset=UTF-8", "apikey" => "test-api-key" }
        )
        .to_return(status: 200, body: '{"id":"123","data":{"name":"Updated"}}', headers: { "Content-Type" => "application/json" })

      result = api.put("/user", body: { data: { name: "Updated" } })
      expect(result).to eq({ "id" => "123", "data" => { "name" => "Updated" } })
    end
  end

  describe "#delete" do
    it "sends a DELETE request" do
      stub_request(:delete, "#{base_url}/admin/users/123")
        .with(headers: { "apikey" => "test-api-key" })
        .to_return(status: 200, body: '{}', headers: { "Content-Type" => "application/json" })

      result = api.delete("/admin/users/123")
      expect(result).to eq({})
    end
  end

  describe "error handling" do
    it "raises AuthApiError on 400 with error_description" do
      stub_request(:post, "#{base_url}/token")
        .to_return(
          status: 400,
          body: '{"error":"invalid_grant","error_description":"Invalid login credentials","error_code":"invalid_grant"}',
          headers: { "Content-Type" => "application/json" }
        )

      expect { api.post("/token", body: {}) }.to raise_error(Supabase::Auth::Errors::AuthApiError) do |e|
        expect(e.message).to eq("Invalid login credentials")
        expect(e.status).to eq(400)
        expect(e.code).to eq("invalid_grant")
      end
    end

    it "raises AuthApiError on 422 with msg field" do
      stub_request(:post, "#{base_url}/signup")
        .to_return(
          status: 422,
          body: '{"msg":"User already registered","error_code":"user_already_exists"}',
          headers: { "Content-Type" => "application/json" }
        )

      expect { api.post("/signup", body: {}) }.to raise_error(Supabase::Auth::Errors::AuthApiError) do |e|
        expect(e.message).to eq("User already registered")
        expect(e.status).to eq(422)
        expect(e.code).to eq("user_already_exists")
      end
    end

    it "raises AuthApiError on 500 server error" do
      stub_request(:get, "#{base_url}/user")
        .to_return(status: 500, body: '{"message":"Internal server error"}', headers: { "Content-Type" => "application/json" })

      expect { api.get("/user") }.to raise_error(Supabase::Auth::Errors::AuthApiError) do |e|
        expect(e.message).to eq("Internal server error")
        expect(e.status).to eq(500)
      end
    end

    it "raises AuthApiError on 401 unauthorized" do
      stub_request(:get, "#{base_url}/user")
        .to_return(
          status: 401,
          body: '{"message":"Invalid token","error_code":"bad_jwt"}',
          headers: { "Content-Type" => "application/json" }
        )

      expect { api.get("/user") }.to raise_error(Supabase::Auth::Errors::AuthApiError) do |e|
        expect(e.message).to eq("Invalid token")
        expect(e.status).to eq(401)
        expect(e.code).to eq("bad_jwt")
      end
    end

    it "raises AuthRetryableError on 502 non-JSON response" do
      stub_request(:get, "#{base_url}/user")
        .to_return(status: 502, body: "Bad Gateway", headers: { "Content-Type" => "text/html" })

      expect { api.get("/user") }.to raise_error(Supabase::Auth::Errors::AuthRetryableError) do |e|
        expect(e.status).to eq(502)
      end
    end

    it "raises AuthUnknownError on empty error response body" do
      stub_request(:get, "#{base_url}/user")
        .to_return(status: 404, body: "", headers: {})

      expect { api.get("/user") }.to raise_error(Supabase::Auth::Errors::AuthUnknownError)
    end
  end

  describe "response parsing" do
    it "returns empty hash for empty response body" do
      stub_request(:post, "#{base_url}/logout")
        .to_return(status: 204, body: nil, headers: {})

      result = api.post("/logout", body: {})
      expect(result).to eq({})
    end

    it "returns empty hash for non-JSON response" do
      stub_request(:get, "#{base_url}/health")
        .to_return(status: 200, body: "OK", headers: { "Content-Type" => "text/plain" })

      result = api.get("/health")
      expect(result).to eq({})
    end
  end

  describe "API version header" do
    it "sends X-Supabase-Api-Version header with value '2024-01-01'" do
      stub_request(:get, "#{base_url}/user")
        .with(headers: { "X-Supabase-Api-Version" => "2024-01-01" })
        .to_return(status: 200, body: '{}', headers: { "Content-Type" => "application/json" })

      api.get("/user")
    end

    it "does not override an explicitly provided API version header" do
      stub_request(:get, "#{base_url}/user")
        .with(headers: { "X-Supabase-Api-Version" => "2025-01-01" })
        .to_return(status: 200, body: '{}', headers: { "Content-Type" => "application/json" })

      api._request(:get, "/user", headers: { "X-Supabase-Api-Version" => "2025-01-01" })
    end
  end

  describe "Authorization header via jwt parameter" do
    it "adds Bearer token when jwt is provided" do
      stub_request(:get, "#{base_url}/user")
        .with(headers: { "Authorization" => "Bearer my-jwt-token" })
        .to_return(status: 200, body: '{"id":"123"}', headers: { "Content-Type" => "application/json" })

      api._request(:get, "/user", jwt: "my-jwt-token")
    end

    it "does not add Authorization header when jwt is nil" do
      stub_request(:get, "#{base_url}/user")
        .to_return(status: 200, body: '{}', headers: { "Content-Type" => "application/json" })

      api._request(:get, "/user")
      expect(WebMock).to have_requested(:get, "#{base_url}/user")
        .with { |req| !req.headers.key?("Authorization") }
    end
  end

  describe "no_resolve_json parameter" do
    it "returns raw Faraday::Response when no_resolve_json is true" do
      stub_request(:post, "#{base_url}/logout")
        .to_return(status: 204, body: "", headers: {})

      result = api._request(:post, "/logout", body: {}, no_resolve_json: true)
      expect(result).to be_a(Faraday::Response)
      expect(result.status).to eq(204)
    end

    it "returns parsed JSON when no_resolve_json is false (default)" do
      stub_request(:get, "#{base_url}/user")
        .to_return(status: 200, body: '{"id":"abc"}', headers: { "Content-Type" => "application/json" })

      result = api._request(:get, "/user")
      expect(result).to eq({ "id" => "abc" })
    end
  end

  describe "redirect_to query parameter" do
    it "appends redirect_to as a query parameter" do
      stub_request(:post, "#{base_url}/recover")
        .with(query: { "redirect_to" => "https://example.com/reset" })
        .to_return(status: 200, body: '{}', headers: { "Content-Type" => "application/json" })

      api._request(:post, "/recover", body: { email: "test@test.com" }, redirect_to: "https://example.com/reset")
    end

    it "merges redirect_to with existing query params" do
      stub_request(:post, "#{base_url}/recover")
        .with(query: { "redirect_to" => "https://example.com/reset", "extra" => "val" })
        .to_return(status: 200, body: '{}', headers: { "Content-Type" => "application/json" })

      api._request(:post, "/recover", body: {}, params: { "extra" => "val" }, redirect_to: "https://example.com/reset")
    end
  end

  describe "xform callback" do
    it "applies xform to parsed JSON result" do
      stub_request(:get, "#{base_url}/user")
        .to_return(status: 200, body: '{"id":"123","email":"test@test.com"}', headers: { "Content-Type" => "application/json" })

      result = api._request(:get, "/user", xform: ->(data) { data["email"] })
      expect(result).to eq("test@test.com")
    end

    it "applies xform to raw response when no_resolve_json is true" do
      stub_request(:post, "#{base_url}/logout")
        .to_return(status: 204, body: "", headers: {})

      result = api._request(:post, "/logout", body: {}, no_resolve_json: true, xform: ->(resp) { resp.status })
      expect(result).to eq(204)
    end
  end

  describe "retryable error handling (502/503/504)" do
    it "raises AuthRetryableError on 503 Service Unavailable" do
      stub_request(:get, "#{base_url}/user")
        .to_return(status: 503, body: "Service Unavailable", headers: { "Content-Type" => "text/html" })

      expect { api.get("/user") }.to raise_error(Supabase::Auth::Errors::AuthRetryableError) do |e|
        expect(e.status).to eq(503)
      end
    end

    it "raises AuthRetryableError on 504 Gateway Timeout" do
      stub_request(:get, "#{base_url}/user")
        .to_return(status: 504, body: "Gateway Timeout", headers: { "Content-Type" => "text/html" })

      expect { api.get("/user") }.to raise_error(Supabase::Auth::Errors::AuthRetryableError) do |e|
        expect(e.status).to eq(504)
      end
    end
  end

  describe "retry constants matching Python" do
    it "has MAX_RETRIES = 10" do
      expect(Supabase::Auth::Constants::MAX_RETRIES).to eq(10)
    end

    it "has RETRY_INTERVAL = 2 (deciseconds)" do
      expect(Supabase::Auth::Constants::RETRY_INTERVAL).to eq(2)
    end
  end

  describe "Content-Type header" do
    it "sets Content-Type to application/json;charset=UTF-8 by default" do
      stub_request(:post, "#{base_url}/signup")
        .with(headers: { "Content-Type" => "application/json;charset=UTF-8" })
        .to_return(status: 200, body: '{}', headers: { "Content-Type" => "application/json" })

      api.post("/signup", body: {})
    end

    it "does not override an explicitly provided Content-Type" do
      stub_request(:post, "#{base_url}/signup")
        .with(headers: { "Content-Type" => "text/plain" })
        .to_return(status: 200, body: '{}', headers: { "Content-Type" => "application/json" })

      api._request(:post, "/signup", body: {}, headers: { "Content-Type" => "text/plain" })
    end
  end

  describe "custom http_client" do
    it "uses the injected Faraday client instead of building one" do
      custom_conn = Faraday.new(url: base_url) do |f|
        f.adapter :test do |stub|
          stub.get("/auth/v1/custom") { [200, { "Content-Type" => "application/json" }, '{"custom":true}'] }
        end
      end

      api = described_class.new(url: base_url, headers: {}, http_client: custom_conn)
      result = api.get("/custom")
      expect(result).to eq({ "custom" => true })
    end
  end
end
