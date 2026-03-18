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
          body: '{"error":"invalid_grant","error_description":"Invalid login credentials"}',
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

    it "handles non-JSON error responses gracefully" do
      stub_request(:get, "#{base_url}/user")
        .to_return(status: 502, body: "Bad Gateway", headers: { "Content-Type" => "text/html" })

      expect { api.get("/user") }.to raise_error(Supabase::Auth::Errors::AuthApiError) do |e|
        expect(e.status).to eq(502)
      end
    end

    it "handles empty error response body" do
      stub_request(:get, "#{base_url}/user")
        .to_return(status: 404, body: "", headers: {})

      expect { api.get("/user") }.to raise_error(Supabase::Auth::Errors::AuthApiError) do |e|
        expect(e.status).to eq(404)
      end
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
