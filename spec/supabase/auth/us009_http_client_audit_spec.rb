# frozen_string_literal: true

require "spec_helper"
require "json"
require "faraday"

RSpec.describe "US-009: Audit HTTP Client / Base API" do
  let(:base_url) { "http://localhost:9999" }
  let(:default_headers) { { "apikey" => "test-key" } }
  let(:api) { Supabase::Auth::Api.new(url: base_url, headers: default_headers) }

  # Stub connection helper — returns a Faraday connection with stubs
  def build_api_with_stubs(&block)
    stubs = Faraday::Adapter::Test::Stubs.new(&block)
    conn = Faraday.new(url: base_url) do |f|
      f.response :raise_error
      f.adapter :test, stubs
    end
    api = Supabase::Auth::Api.new(url: base_url, headers: default_headers, http_client: conn)
    [api, stubs]
  end

  describe "AC-1: Content-Type header" do
    it "sets Content-Type to application/json;charset=UTF-8" do
      expect(Supabase::Auth::Api::CONTENT_TYPE).to eq("application/json;charset=UTF-8")
    end

    it "includes Content-Type in requests" do
      captured_headers = nil
      api, stubs = build_api_with_stubs do |stub|
        stub.get("/test") do |env|
          captured_headers = env.request_headers
          [200, { "Content-Type" => "application/json" }, "{}"]
        end
      end

      api._request(:get, "test")
      stubs.verify_stubbed_calls

      expect(captured_headers["Content-Type"]).to eq("application/json;charset=UTF-8")
    end

    it "does not override explicit Content-Type" do
      captured_headers = nil
      api, stubs = build_api_with_stubs do |stub|
        stub.post("/upload") do |env|
          captured_headers = env.request_headers
          [200, { "Content-Type" => "application/json" }, "{}"]
        end
      end

      api._request(:post, "upload", headers: { "Content-Type" => "multipart/form-data" })
      stubs.verify_stubbed_calls

      expect(captured_headers["Content-Type"]).to eq("multipart/form-data")
    end
  end

  describe "AC-2: API version header" do
    it "sends X-Supabase-Api-Version header with value 2024-01-01" do
      captured_headers = nil
      api, stubs = build_api_with_stubs do |stub|
        stub.get("/test") do |env|
          captured_headers = env.request_headers
          [200, { "Content-Type" => "application/json" }, "{}"]
        end
      end

      api._request(:get, "test")
      stubs.verify_stubbed_calls

      expect(captured_headers["X-Supabase-Api-Version"]).to eq("2024-01-01")
    end

    it "matches Python's API_VERSION_HEADER_NAME constant" do
      expect(Supabase::Auth::Constants::API_VERSION_HEADER_NAME).to eq("X-Supabase-Api-Version")
    end

    it "matches Python's API_VERSIONS structure" do
      versions = Supabase::Auth::Constants::API_VERSIONS
      expect(versions).to have_key("2024-01-01")
      expect(versions["2024-01-01"]["name"]).to eq("2024-01-01")
      expect(versions["2024-01-01"]["timestamp"]).to be_a(Float)
    end

    it "does not override explicit API version header" do
      captured_headers = nil
      api, stubs = build_api_with_stubs do |stub|
        stub.get("/test") do |env|
          captured_headers = env.request_headers
          [200, { "Content-Type" => "application/json" }, "{}"]
        end
      end

      api._request(:get, "test", headers: { "X-Supabase-Api-Version" => "2025-01-01" })
      stubs.verify_stubbed_calls

      expect(captured_headers["X-Supabase-Api-Version"]).to eq("2025-01-01")
    end
  end

  describe "AC-3: Authorization Bearer token header" do
    it "adds Authorization header when jwt is provided" do
      captured_headers = nil
      api, stubs = build_api_with_stubs do |stub|
        stub.get("/user") do |env|
          captured_headers = env.request_headers
          [200, { "Content-Type" => "application/json" }, '{"id": "123"}']
        end
      end

      api._request(:get, "user", jwt: "my-secret-token")
      stubs.verify_stubbed_calls

      expect(captured_headers["Authorization"]).to eq("Bearer my-secret-token")
    end

    it "does not add Authorization header when jwt is nil" do
      captured_headers = nil
      api, stubs = build_api_with_stubs do |stub|
        stub.get("/public") do |env|
          captured_headers = env.request_headers
          [200, { "Content-Type" => "application/json" }, "{}"]
        end
      end

      api._request(:get, "public")
      stubs.verify_stubbed_calls

      expect(captured_headers).not_to have_key("Authorization")
    end

    it "formats Bearer token matching Python: 'Bearer {jwt}'" do
      captured_headers = nil
      api, stubs = build_api_with_stubs do |stub|
        stub.post("/token") do |env|
          captured_headers = env.request_headers
          [200, { "Content-Type" => "application/json" }, '{"access_token": "abc"}']
        end
      end

      api._request(:post, "token", jwt: "abc123", body: {})
      stubs.verify_stubbed_calls

      expect(captured_headers["Authorization"]).to match(/\ABearer .+\z/)
    end
  end

  describe "AC-4: no_resolve_json parameter" do
    it "returns raw Faraday::Response when no_resolve_json is true" do
      api, stubs = build_api_with_stubs do |stub|
        stub.post("/logout") do |_env|
          [204, {}, ""]
        end
      end

      result = api._request(:post, "logout", no_resolve_json: true)
      stubs.verify_stubbed_calls

      expect(result).to be_a(Faraday::Response)
      expect(result.status).to eq(204)
    end

    it "returns parsed JSON when no_resolve_json is false (default)" do
      api, stubs = build_api_with_stubs do |stub|
        stub.get("/data") do |_env|
          [200, { "Content-Type" => "application/json" }, '{"key": "value"}']
        end
      end

      result = api._request(:get, "data")
      stubs.verify_stubbed_calls

      expect(result).to eq({ "key" => "value" })
    end

    it "xform receives raw response when no_resolve_json is true" do
      api, stubs = build_api_with_stubs do |stub|
        stub.get("/raw") do |_env|
          [200, { "X-Custom" => "header-val" }, "raw body"]
        end
      end

      result = api._request(:get, "raw", no_resolve_json: true, xform: ->(resp) { resp.headers["X-Custom"] })
      stubs.verify_stubbed_calls

      expect(result).to eq("header-val")
    end
  end

  describe "AC-5: Query parameters" do
    it "appends query parameters to URL" do
      captured_params = nil
      api, stubs = build_api_with_stubs do |stub|
        stub.get("/users") do |env|
          captured_params = env.params
          [200, { "Content-Type" => "application/json" }, "[]"]
        end
      end

      api._request(:get, "users", params: { "page" => "1", "per_page" => "10" })
      stubs.verify_stubbed_calls

      expect(captured_params["page"]).to eq("1")
      expect(captured_params["per_page"]).to eq("10")
    end

    it "adds redirect_to as query parameter" do
      captured_params = nil
      api, stubs = build_api_with_stubs do |stub|
        stub.post("/invite") do |env|
          captured_params = env.params
          [200, { "Content-Type" => "application/json" }, "{}"]
        end
      end

      api._request(:post, "invite", body: { email: "a@b.com" }, redirect_to: "https://example.com/callback")
      stubs.verify_stubbed_calls

      expect(captured_params["redirect_to"]).to eq("https://example.com/callback")
    end

    it "merges redirect_to with other query params" do
      captured_params = nil
      api, stubs = build_api_with_stubs do |stub|
        stub.post("/token") do |env|
          captured_params = env.params
          [200, { "Content-Type" => "application/json" }, "{}"]
        end
      end

      api._request(:post, "token", params: { "grant_type" => "refresh_token" }, redirect_to: "https://example.com")
      stubs.verify_stubbed_calls

      expect(captured_params["grant_type"]).to eq("refresh_token")
      expect(captured_params["redirect_to"]).to eq("https://example.com")
    end

    it "does not add redirect_to when nil" do
      captured_params = nil
      api, stubs = build_api_with_stubs do |stub|
        stub.get("/test") do |env|
          captured_params = env.params
          [200, { "Content-Type" => "application/json" }, "{}"]
        end
      end

      api._request(:get, "test")
      stubs.verify_stubbed_calls

      expect(captured_params).not_to have_key("redirect_to")
    end
  end

  describe "AC-6: Request retry logic" do
    it "defines MAX_RETRIES=10 matching Python" do
      expect(Supabase::Auth::Constants::MAX_RETRIES).to eq(10)
    end

    it "defines RETRY_INTERVAL=2 matching Python" do
      expect(Supabase::Auth::Constants::RETRY_INTERVAL).to eq(2)
    end

    it "raises AuthRetryableError for 502 status" do
      api, stubs = build_api_with_stubs do |stub|
        stub.get("/test") do |_env|
          [502, {}, "Bad Gateway"]
        end
      end

      expect { api._request(:get, "test") }.to raise_error(Supabase::Auth::Errors::AuthRetryableError) do |e|
        expect(e.status).to eq(502)
      end
    end

    it "raises AuthRetryableError for 503 status" do
      api, stubs = build_api_with_stubs do |stub|
        stub.get("/test") do |_env|
          [503, {}, "Service Unavailable"]
        end
      end

      expect { api._request(:get, "test") }.to raise_error(Supabase::Auth::Errors::AuthRetryableError) do |e|
        expect(e.status).to eq(503)
      end
    end

    it "raises AuthRetryableError for 504 status" do
      api, stubs = build_api_with_stubs do |stub|
        stub.get("/test") do |_env|
          [504, {}, "Gateway Timeout"]
        end
      end

      expect { api._request(:get, "test") }.to raise_error(Supabase::Auth::Errors::AuthRetryableError) do |e|
        expect(e.status).to eq(504)
      end
    end

    it "raises AuthRetryableError for non-HTTP errors (e.g., network failures)" do
      api, stubs = build_api_with_stubs do |stub|
        stub.get("/test") do |_env|
          raise Faraday::ConnectionFailed, "Connection refused"
        end
      end

      expect { api._request(:get, "test") }.to raise_error(Supabase::Auth::Errors::AuthRetryableError) do |e|
        expect(e.status).to eq(0)
      end
    end

    it "raises AuthApiError for 400 status" do
      api, stubs = build_api_with_stubs do |stub|
        stub.post("/signup") do |_env|
          [400, { "Content-Type" => "application/json" }, '{"error": "Bad request"}']
        end
      end

      expect { api._request(:post, "signup", body: {}) }.to raise_error(Supabase::Auth::Errors::AuthApiError) do |e|
        expect(e.status).to eq(400)
      end
    end

    it "raises AuthApiError for 401 status" do
      api, stubs = build_api_with_stubs do |stub|
        stub.get("/user") do |_env|
          [401, { "Content-Type" => "application/json" }, '{"error": "Unauthorized"}']
        end
      end

      expect { api._request(:get, "user") }.to raise_error(Supabase::Auth::Errors::AuthApiError) do |e|
        expect(e.status).to eq(401)
      end
    end
  end

  describe "AC-7: Response body parsing" do
    it "returns empty hash for nil body" do
      api, stubs = build_api_with_stubs do |stub|
        stub.delete("/session") do |_env|
          [200, { "Content-Type" => "application/json" }, nil]
        end
      end

      result = api._request(:delete, "session")
      stubs.verify_stubbed_calls

      expect(result).to eq({})
    end

    it "returns empty hash for empty body" do
      api, stubs = build_api_with_stubs do |stub|
        stub.delete("/session") do |_env|
          [200, { "Content-Type" => "application/json" }, ""]
        end
      end

      result = api._request(:delete, "session")
      stubs.verify_stubbed_calls

      expect(result).to eq({})
    end

    it "returns empty hash for unparseable body" do
      api, stubs = build_api_with_stubs do |stub|
        stub.get("/broken") do |_env|
          [200, { "Content-Type" => "text/html" }, "<html>not json</html>"]
        end
      end

      result = api._request(:get, "broken")
      stubs.verify_stubbed_calls

      expect(result).to eq({})
    end

    it "parses valid JSON body" do
      api, stubs = build_api_with_stubs do |stub|
        stub.get("/data") do |_env|
          [200, { "Content-Type" => "application/json" }, '{"users": [{"id": 1}]}']
        end
      end

      result = api._request(:get, "data")
      stubs.verify_stubbed_calls

      expect(result).to eq({ "users" => [{ "id" => 1 }] })
    end
  end

  describe "Header merging" do
    it "merges default headers with per-request headers" do
      captured_headers = nil
      api, stubs = build_api_with_stubs do |stub|
        stub.get("/test") do |env|
          captured_headers = env.request_headers
          [200, { "Content-Type" => "application/json" }, "{}"]
        end
      end

      api._request(:get, "test", headers: { "X-Custom" => "value" })
      stubs.verify_stubbed_calls

      expect(captured_headers["apikey"]).to eq("test-key")
      expect(captured_headers["X-Custom"]).to eq("value")
    end

    it "per-request headers override default headers" do
      captured_headers = nil
      api, stubs = build_api_with_stubs do |stub|
        stub.get("/test") do |env|
          captured_headers = env.request_headers
          [200, { "Content-Type" => "application/json" }, "{}"]
        end
      end

      api._request(:get, "test", headers: { "apikey" => "override-key" })
      stubs.verify_stubbed_calls

      expect(captured_headers["apikey"]).to eq("override-key")
    end
  end

  describe "Request body serialization" do
    it "serializes body as JSON" do
      captured_body = nil
      api, stubs = build_api_with_stubs do |stub|
        stub.post("/signup") do |env|
          captured_body = env.body
          [200, { "Content-Type" => "application/json" }, '{"user": {}}']
        end
      end

      api._request(:post, "signup", body: { email: "test@example.com", password: "secret" })
      stubs.verify_stubbed_calls

      parsed = JSON.parse(captured_body)
      expect(parsed["email"]).to eq("test@example.com")
      expect(parsed["password"]).to eq("secret")
    end

    it "sends nil body for GET requests without body" do
      captured_body = nil
      api, stubs = build_api_with_stubs do |stub|
        stub.get("/test") do |env|
          captured_body = env.body
          [200, { "Content-Type" => "application/json" }, "{}"]
        end
      end

      api._request(:get, "test")
      stubs.verify_stubbed_calls

      expect(captured_body).to be_nil
    end
  end

  describe "xform callback" do
    it "applies xform to parsed response" do
      api, stubs = build_api_with_stubs do |stub|
        stub.get("/user") do |_env|
          [200, { "Content-Type" => "application/json" }, '{"user": {"id": "abc"}}']
        end
      end

      result = api._request(:get, "user", xform: ->(data) { data["user"]["id"] })
      stubs.verify_stubbed_calls

      expect(result).to eq("abc")
    end

    it "returns parsed response when xform is nil" do
      api, stubs = build_api_with_stubs do |stub|
        stub.get("/data") do |_env|
          [200, { "Content-Type" => "application/json" }, '{"key": "val"}']
        end
      end

      result = api._request(:get, "data")
      stubs.verify_stubbed_calls

      expect(result).to eq({ "key" => "val" })
    end
  end

  describe "Convenience methods" do
    it "get delegates to _request with :get method" do
      api, stubs = build_api_with_stubs do |stub|
        stub.get("/test") do |_env|
          [200, { "Content-Type" => "application/json" }, '{"ok": true}']
        end
      end

      result = api.get("test")
      stubs.verify_stubbed_calls

      expect(result).to eq({ "ok" => true })
    end

    it "post delegates to _request with :post method and body" do
      captured_body = nil
      api, stubs = build_api_with_stubs do |stub|
        stub.post("/create") do |env|
          captured_body = env.body
          [200, { "Content-Type" => "application/json" }, "{}"]
        end
      end

      api.post("create", body: { name: "test" })
      stubs.verify_stubbed_calls

      expect(JSON.parse(captured_body)).to eq({ "name" => "test" })
    end

    it "put delegates to _request with :put method and body" do
      captured_body = nil
      api, stubs = build_api_with_stubs do |stub|
        stub.put("/update") do |env|
          captured_body = env.body
          [200, { "Content-Type" => "application/json" }, "{}"]
        end
      end

      api.put("update", body: { name: "updated" })
      stubs.verify_stubbed_calls

      expect(JSON.parse(captured_body)).to eq({ "name" => "updated" })
    end

    it "delete delegates to _request with :delete method" do
      api, stubs = build_api_with_stubs do |stub|
        stub.delete("/remove") do |_env|
          [200, { "Content-Type" => "application/json" }, "{}"]
        end
      end

      result = api.delete("remove")
      stubs.verify_stubbed_calls

      expect(result).to eq({})
    end
  end

  describe "Custom HTTP client" do
    it "uses provided http_client instead of building one" do
      stubs = Faraday::Adapter::Test::Stubs.new do |stub|
        stub.get("/custom") do |_env|
          [200, { "Content-Type" => "application/json" }, '{"source": "custom"}']
        end
      end
      custom_conn = Faraday.new(url: base_url) do |f|
        f.response :raise_error
        f.adapter :test, stubs
      end

      api = Supabase::Auth::Api.new(url: base_url, headers: default_headers, http_client: custom_conn)
      result = api._request(:get, "custom")
      stubs.verify_stubbed_calls

      expect(result).to eq({ "source" => "custom" })
    end
  end

  describe "Constants parity with Python" do
    it "GOTRUE_URL matches Python default" do
      expect(Supabase::Auth::Constants::GOTRUE_URL).to eq("http://localhost:9999")
    end

    it "EXPIRY_MARGIN matches Python (10 seconds)" do
      expect(Supabase::Auth::Constants::EXPIRY_MARGIN).to eq(10)
    end

    it "STORAGE_KEY matches Python" do
      expect(Supabase::Auth::Constants::STORAGE_KEY).to eq("supabase.auth.token")
    end

    it "DEFAULT_HEADERS includes X-Client-Info" do
      expect(Supabase::Auth::Constants::DEFAULT_HEADERS).to have_key("X-Client-Info")
      expect(Supabase::Auth::Constants::DEFAULT_HEADERS["X-Client-Info"]).to match(/\Agotrue-rb\//)
    end

    it "BASE64URL_REGEX matches Python pattern" do
      regex = Supabase::Auth::Constants::BASE64URL_REGEX
      expect("abc123_-ABC").to match(regex)
      expect("!!!").not_to match(regex)
    end
  end

  describe "URL path building" do
    it "correctly builds path from base URL" do
      captured_url = nil
      api, stubs = build_api_with_stubs do |stub|
        stub.get("/user") do |env|
          captured_url = env.url.path
          [200, { "Content-Type" => "application/json" }, "{}"]
        end
      end

      api._request(:get, "user")
      stubs.verify_stubbed_calls

      expect(captured_url).to eq("/user")
    end

    it "handles leading slash in path" do
      captured_url = nil
      api, stubs = build_api_with_stubs do |stub|
        stub.get("/user") do |env|
          captured_url = env.url.path
          [200, { "Content-Type" => "application/json" }, "{}"]
        end
      end

      api._request(:get, "/user")
      stubs.verify_stubbed_calls

      expect(captured_url).to eq("/user")
    end
  end

  describe "UUID validation" do
    it "accepts valid UUIDs" do
      expect { api._validate_uuid("550e8400-e29b-41d4-a716-446655440000") }.not_to raise_error
    end

    it "rejects invalid UUIDs" do
      expect { api._validate_uuid("not-a-uuid") }.to raise_error(ArgumentError)
    end

    it "rejects nil" do
      expect { api._validate_uuid(nil) }.to raise_error(ArgumentError)
    end

    it "rejects non-string" do
      expect { api._validate_uuid(123) }.to raise_error(ArgumentError)
    end
  end
end
