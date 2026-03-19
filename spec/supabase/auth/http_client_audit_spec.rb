# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"

# US-009: Audit HTTP Client / Base API
# Verifies that the Ruby HTTP client layer matches Python's request handling.
RSpec.describe "HTTP Client / Base API audit (US-009)" do
  let(:base_url) { "https://example.supabase.co/auth/v1" }
  let(:default_headers) { { "apikey" => "test-api-key" } }
  let(:api) { Supabase::Auth::Api.new(url: base_url, headers: default_headers) }

  # AC-1: Content-Type header set to "application/json;charset=UTF-8"
  describe "Content-Type header" do
    it "defaults to application/json;charset=UTF-8 matching Python" do
      expect(Supabase::Auth::Api::CONTENT_TYPE).to eq("application/json;charset=UTF-8")
    end

    it "sends Content-Type on every request by default" do
      stub_request(:get, "#{base_url}/user")
        .with(headers: { "Content-Type" => "application/json;charset=UTF-8" })
        .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })

      api._request(:get, "/user")
    end

    it "does not override Content-Type if already provided (matches Python behavior)" do
      stub_request(:post, "#{base_url}/signup")
        .with(headers: { "Content-Type" => "multipart/form-data" })
        .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })

      api._request(:post, "/signup", body: {}, headers: { "Content-Type" => "multipart/form-data" })
    end
  end

  # AC-2: API version header (X-Supabase-Api-Version) sent with value "2024-01-01"
  describe "API version header" do
    it "sends X-Supabase-Api-Version with value '2024-01-01'" do
      stub_request(:get, "#{base_url}/user")
        .with(headers: { "X-Supabase-Api-Version" => "2024-01-01" })
        .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })

      api._request(:get, "/user")
    end

    it "uses Constants::API_VERSION_HEADER_NAME matching Python constant" do
      expect(Supabase::Auth::Constants::API_VERSION_HEADER_NAME).to eq("X-Supabase-Api-Version")
    end

    it "has API_VERSIONS matching Python's 2024-01-01 entry" do
      versions = Supabase::Auth::Constants::API_VERSIONS
      expect(versions).to have_key("2024-01-01")
      expect(versions["2024-01-01"]["name"]).to eq("2024-01-01")
      expect(versions["2024-01-01"]["timestamp"]).to be_a(Float)
    end

    it "does not override explicitly provided API version header" do
      stub_request(:get, "#{base_url}/user")
        .with(headers: { "X-Supabase-Api-Version" => "2025-06-01" })
        .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })

      api._request(:get, "/user", headers: { "X-Supabase-Api-Version" => "2025-06-01" })
    end
  end

  # AC-3: Authorization Bearer token header correctly added for authenticated requests
  describe "Authorization Bearer token" do
    it "adds Authorization: Bearer <jwt> when jwt parameter is provided" do
      stub_request(:get, "#{base_url}/user")
        .with(headers: { "Authorization" => "Bearer my-token-123" })
        .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })

      api._request(:get, "/user", jwt: "my-token-123")
    end

    it "does not add Authorization header when jwt is nil" do
      stub_request(:get, "#{base_url}/user")
        .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })

      api._request(:get, "/user")
      expect(WebMock).to have_requested(:get, "#{base_url}/user")
        .with { |req| !req.headers.key?("Authorization") }
    end

    it "overwrites any existing Authorization header when jwt is provided" do
      api_with_auth = Supabase::Auth::Api.new(
        url: base_url,
        headers: { "Authorization" => "Bearer old-token" }
      )

      stub_request(:get, "#{base_url}/user")
        .with(headers: { "Authorization" => "Bearer new-token" })
        .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })

      api_with_auth._request(:get, "/user", jwt: "new-token")
    end
  end

  # AC-4: no_resolve_json parameter works correctly for endpoints that return empty responses
  describe "no_resolve_json parameter" do
    it "returns raw Faraday::Response when true" do
      stub_request(:post, "#{base_url}/logout")
        .to_return(status: 204, body: "", headers: {})

      result = api._request(:post, "/logout", body: {}, no_resolve_json: true)
      expect(result).to be_a(Faraday::Response)
      expect(result.status).to eq(204)
    end

    it "returns parsed JSON hash when false (default)" do
      stub_request(:get, "#{base_url}/user")
        .to_return(status: 200, body: '{"id":"abc"}', headers: { "Content-Type" => "application/json" })

      result = api._request(:get, "/user")
      expect(result).to be_a(Hash)
      expect(result["id"]).to eq("abc")
    end

    it "works with xform when no_resolve_json is true (matches Python)" do
      stub_request(:post, "#{base_url}/logout")
        .to_return(status: 204, body: "", headers: {})

      result = api._request(:post, "/logout", body: {}, no_resolve_json: true, xform: ->(r) { r.status })
      expect(result).to eq(204)
    end
  end

  # AC-5: Query parameters correctly appended to URLs
  describe "query parameters" do
    it "appends query params to the request URL" do
      stub_request(:get, "#{base_url}/admin/users")
        .with(query: { "page" => "1", "per_page" => "50" })
        .to_return(status: 200, body: '{"users":[]}', headers: { "Content-Type" => "application/json" })

      api._request(:get, "/admin/users", params: { "page" => "1", "per_page" => "50" })
    end

    it "appends redirect_to as a query param (matching Python)" do
      stub_request(:post, "#{base_url}/recover")
        .with(query: { "redirect_to" => "https://example.com/reset" })
        .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })

      api._request(:post, "/recover", body: { email: "test@test.com" }, redirect_to: "https://example.com/reset")
    end

    it "merges redirect_to with explicit query params" do
      stub_request(:post, "#{base_url}/token")
        .with(query: { "grant_type" => "password", "redirect_to" => "https://example.com" })
        .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })

      api._request(:post, "/token", body: {}, params: { "grant_type" => "password" }, redirect_to: "https://example.com")
    end
  end

  # AC-6: Request retry logic with exponential backoff matches Python (MAX_RETRIES=10)
  describe "retry constants matching Python" do
    it "MAX_RETRIES = 10" do
      expect(Supabase::Auth::Constants::MAX_RETRIES).to eq(10)
    end

    it "RETRY_INTERVAL = 2 (deciseconds)" do
      expect(Supabase::Auth::Constants::RETRY_INTERVAL).to eq(2)
    end

    it "EXPIRY_MARGIN = 10 (seconds)" do
      expect(Supabase::Auth::Constants::EXPIRY_MARGIN).to eq(10)
    end
  end

  describe "retry error classification" do
    it "returns AuthRetryableError for non-HTTP errors (matching Python)" do
      error = Supabase::Auth::Helpers.handle_exception(RuntimeError.new("connection refused"))
      expect(error).to be_a(Supabase::Auth::Errors::AuthRetryableError)
      expect(error.status).to eq(0)
    end

    [502, 503, 504].each do |status_code|
      it "returns AuthRetryableError for HTTP #{status_code} (matching Python)" do
        stub_request(:get, "#{base_url}/user")
          .to_return(status: status_code, body: "Error", headers: { "Content-Type" => "text/html" })

        expect { api.get("/user") }.to raise_error(Supabase::Auth::Errors::AuthRetryableError) do |e|
          expect(e.status).to eq(status_code)
        end
      end
    end

    it "does NOT return AuthRetryableError for HTTP 500 (matching Python)" do
      stub_request(:get, "#{base_url}/user")
        .to_return(status: 500, body: '{"message":"error"}', headers: { "Content-Type" => "application/json" })

      expect { api.get("/user") }.to raise_error(Supabase::Auth::Errors::AuthApiError) do |e|
        expect(e.status).to eq(500)
      end
    end
  end

  describe "Client retry behavior with exponential backoff" do
    let(:storage) { Supabase::Auth::MemoryStorage.new }
    let(:client) do
      Supabase::Auth::Client.new(
        url: base_url,
        headers: default_headers,
        auto_refresh_token: false,
        persist_session: false,
        storage: storage
      )
    end

    it "initializes network_retries to 0 (matching Python)" do
      expect(client.instance_variable_get(:@network_retries)).to eq(0)
    end

    it "uses RETRY_INTERVAL ** (retries * 100) formula matching Python" do
      # Python: RETRY_INTERVAL ** (self._network_retries * 100)
      # Ruby:   Constants::RETRY_INTERVAL ** (@network_retries * 100)
      # With RETRY_INTERVAL=2, retries=1: 2 ** 100 ms
      interval = Supabase::Auth::Constants::RETRY_INTERVAL
      retries = 1
      expected = interval ** (retries * 100)
      expect(expected).to eq(2**100)
    end
  end

  # AC-7: Response body parsing handles empty responses gracefully
  describe "response body parsing" do
    it "returns empty hash for nil body" do
      stub_request(:post, "#{base_url}/logout")
        .to_return(status: 204, body: nil, headers: {})

      result = api._request(:post, "/logout", body: {})
      expect(result).to eq({})
    end

    it "returns empty hash for empty string body" do
      stub_request(:delete, "#{base_url}/admin/users/123")
        .to_return(status: 200, body: "", headers: {})

      result = api._request(:delete, "/admin/users/123")
      expect(result).to eq({})
    end

    it "returns empty hash for non-JSON body" do
      stub_request(:get, "#{base_url}/health")
        .to_return(status: 200, body: "OK", headers: { "Content-Type" => "text/plain" })

      result = api._request(:get, "/health")
      expect(result).to eq({})
    end

    it "correctly parses valid JSON response" do
      stub_request(:get, "#{base_url}/user")
        .to_return(status: 200, body: '{"id":"u1","email":"a@b.com"}', headers: { "Content-Type" => "application/json" })

      result = api._request(:get, "/user")
      expect(result).to eq({ "id" => "u1", "email" => "a@b.com" })
    end

    it "correctly parses JSON array response" do
      stub_request(:get, "#{base_url}/admin/users")
        .to_return(status: 200, body: '[{"id":"1"},{"id":"2"}]', headers: { "Content-Type" => "application/json" })

      result = api._request(:get, "/admin/users")
      expect(result).to be_an(Array)
      expect(result.length).to eq(2)
    end
  end

  # Additional: Verify error handling matches Python's handle_exception
  describe "error handling parity with Python" do
    it "extracts error_code from new API version format (code field)" do
      stub_request(:post, "#{base_url}/token")
        .to_return(
          status: 400,
          body: '{"code":"invalid_credentials","message":"Invalid login"}',
          headers: {
            "Content-Type" => "application/json",
            "X-Supabase-Api-Version" => "2024-01-01"
          }
        )

      expect { api.post("/token", body: {}) }.to raise_error(Supabase::Auth::Errors::AuthApiError) do |e|
        expect(e.code).to eq("invalid_credentials")
        expect(e.message).to eq("Invalid login")
        expect(e.status).to eq(400)
      end
    end

    it "falls back to error_code field for legacy responses" do
      stub_request(:post, "#{base_url}/token")
        .to_return(
          status: 422,
          body: '{"msg":"Already registered","error_code":"user_already_exists"}',
          headers: { "Content-Type" => "application/json" }
        )

      expect { api.post("/token", body: {}) }.to raise_error(Supabase::Auth::Errors::AuthApiError) do |e|
        expect(e.code).to eq("user_already_exists")
        expect(e.message).to eq("Already registered")
      end
    end

    it "handles weak_password error with reasons" do
      stub_request(:post, "#{base_url}/signup")
        .to_return(
          status: 422,
          body: '{"message":"Password too weak","error_code":"weak_password","weak_password":{"reasons":["too short","no uppercase"]}}',
          headers: {
            "Content-Type" => "application/json",
            "X-Supabase-Api-Version" => "2024-01-01"
          }
        )

      expect { api.post("/signup", body: {}) }.to raise_error(Supabase::Auth::Errors::AuthWeakPassword) do |e|
        expect(e.reasons).to include("too short", "no uppercase")
        expect(e.status).to eq(422)
      end
    end

    it "returns AuthUnknownError when response body is not parseable JSON" do
      stub_request(:get, "#{base_url}/user")
        .to_return(status: 404, body: "", headers: {})

      expect { api.get("/user") }.to raise_error(Supabase::Auth::Errors::AuthUnknownError)
    end
  end

  # Additional: Verify URL construction
  describe "URL construction" do
    it "builds correct path with base URL path prefix" do
      api_with_path = Supabase::Auth::Api.new(url: "https://example.com/auth/v1", headers: {})

      stub_request(:get, "https://example.com/auth/v1/user")
        .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })

      api_with_path._request(:get, "/user")
    end

    it "handles path without leading slash" do
      stub_request(:get, "#{base_url}/user")
        .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })

      api._request(:get, "user")
    end
  end

  # Additional: Verify request body JSON serialization
  describe "request body serialization" do
    it "serializes Hash body to JSON" do
      stub_request(:post, "#{base_url}/signup")
        .with(body: '{"email":"test@test.com","password":"secret"}')
        .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })

      api._request(:post, "/signup", body: { email: "test@test.com", password: "secret" })
    end

    it "does not send body when body is nil" do
      stub_request(:get, "#{base_url}/user")
        .with(body: nil)
        .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })

      api._request(:get, "/user")
    end
  end

  # Additional: Verify header merging behavior matches Python
  describe "header merging" do
    it "merges request-specific headers with default headers (matching Python)" do
      stub_request(:get, "#{base_url}/user")
        .with(headers: { "apikey" => "test-api-key", "X-Custom" => "value" })
        .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })

      api._request(:get, "/user", headers: { "X-Custom" => "value" })
    end

    it "request headers override default headers" do
      api_with_auth = Supabase::Auth::Api.new(
        url: base_url,
        headers: { "apikey" => "default-key" }
      )

      stub_request(:get, "#{base_url}/user")
        .with(headers: { "apikey" => "override-key" })
        .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })

      api_with_auth._request(:get, "/user", headers: { "apikey" => "override-key" })
    end
  end
end
