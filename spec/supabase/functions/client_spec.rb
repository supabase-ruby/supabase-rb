# frozen_string_literal: true

require "supabase/functions"
require "webmock/rspec"
require "json"

RSpec.describe Supabase::Functions::Client do
  let(:base) { "https://x.supabase.co/functions/v1" }
  let(:client) do
    described_class.new(
      base_url: base,
      headers:  { "Authorization" => "Bearer tok", "apikey" => "anon" }
    )
  end

  before { WebMock.disable_net_connect! }
  after  { WebMock.allow_net_connect! }

  # ---------------------------------------------------------------------------
  # Constructor
  # ---------------------------------------------------------------------------

  describe "#initialize" do
    it "stamps the X-Client-Info header and keeps user headers" do
      expect(client.headers["X-Client-Info"]).to match(%r{supabase-rb/functions-rb v})
      expect(client.headers["Authorization"]).to eq("Bearer tok")
    end

    it "strips a trailing slash from the base URL" do
      c = described_class.new(base_url: "https://x.supabase.co/functions/v1/")
      expect(c.base_url).to eq("https://x.supabase.co/functions/v1")
    end

    it "rejects URLs that aren't http(s)" do
      expect { described_class.new(base_url: "ftp://x.com") }
        .to raise_error(ArgumentError, /http/)
    end

    it "rejects malformed URLs" do
      expect { described_class.new(base_url: "not a url at all") }
        .to raise_error(ArgumentError)
    end
  end

  describe "#set_auth" do
    it "overwrites the Authorization header so future invocations use the new token" do
      client.set_auth("new-token")
      expect(client.headers["Authorization"]).to eq("Bearer new-token")
    end
  end

  # ---------------------------------------------------------------------------
  # Invoke — body / headers / method
  # ---------------------------------------------------------------------------

  describe "#invoke" do
    it "POSTs to /<function_name> by default with the JSON body encoded" do
      stub_request(:post, "#{base}/hello")
        .with(body: JSON.generate("name" => "Ada"),
              headers: { "Content-Type" => "application/json", "Authorization" => "Bearer tok" })
        .to_return(status: 200, body: JSON.generate("ok" => true),
                   headers: { "Content-Type" => "application/json" })

      r = client.invoke("hello", body: { name: "Ada" })
      expect(r).to be_a(Supabase::Functions::Types::Response)
      expect(r.status).to eq(200)
      expect(r.data).to eq("ok" => true)
    end

    it "sends a String body as text/plain without JSON-encoding it" do
      stub_request(:post, "#{base}/hello")
        .with(body: "raw payload",
              headers: { "Content-Type" => "text/plain" })
        .to_return(status: 200, body: "")

      client.invoke("hello", body: "raw payload")
    end

    it "doesn't add a Content-Type when the body is nil (GET-style invocations)" do
      stub = stub_request(:get, "#{base}/ping")
             .with { |req| !req.headers.key?("Content-Type") || req.headers["Content-Type"] != "application/json" }
             .to_return(status: 200, body: "")

      client.invoke("ping", method: "GET")
      expect(stub).to have_been_requested
    end

    it "supports custom per-invocation headers (merged over client defaults)" do
      stub_request(:post, "#{base}/hello")
        .with(headers: { "X-Custom" => "header", "Authorization" => "Bearer tok" })
        .to_return(status: 200, body: "")

      client.invoke("hello", headers: { "X-Custom" => "header" })
    end

    it "honors the method: parameter for PUT/PATCH/DELETE/HEAD/OPTIONS" do
      %w[PUT PATCH DELETE HEAD OPTIONS].each do |m|
        stub_request(m.downcase.to_sym, "#{base}/fn").to_return(status: 200, body: "")
        client.invoke("fn", method: m)
      end
    end

    it "rejects unknown HTTP methods" do
      expect { client.invoke("fn", method: "FOO") }
        .to raise_error(ArgumentError, /method/)
    end

    it "rejects blank function names" do
      expect { client.invoke("") }.to raise_error(ArgumentError, /function_name/)
      expect { client.invoke("   ") }.to raise_error(ArgumentError, /function_name/)
      expect { client.invoke(nil) }.to raise_error(ArgumentError, /function_name/)
    end

    it "rejects body types that aren't String / Hash / Array / nil" do
      expect { client.invoke("fn", body: 42) }
        .to raise_error(ArgumentError, /body must be/)
    end

    it "passes query: as the query string" do
      stub_request(:post, "#{base}/fn")
        .with(query: { "a" => "1", "b" => "2" })
        .to_return(status: 200, body: "")

      client.invoke("fn", query: { a: 1, b: "2" })
    end
  end

  # ---------------------------------------------------------------------------
  # Region — sets x-region header AND forceFunctionRegion query param
  # ---------------------------------------------------------------------------

  describe "region routing" do
    it "sets the x-region header AND the forceFunctionRegion query param" do
      stub = stub_request(:post, "#{base}/fn")
             .with(query: { "forceFunctionRegion" => "us-east-1" },
                   headers: { "x-region" => "us-east-1" })
             .to_return(status: 200, body: "")

      client.invoke("fn", region: Supabase::Functions::Types::FunctionRegion::US_EAST_1)
      expect(stub).to have_been_requested
    end

    it "skips region wiring when region is 'any' (the platform default)" do
      stub = stub_request(:post, "#{base}/fn")
             .with { |req| !req.headers.key?("x-region") && !req.uri.query.to_s.include?("forceFunctionRegion") }
             .to_return(status: 200, body: "")

      client.invoke("fn", region: "any")
      expect(stub).to have_been_requested
    end

    it "accepts a bare string region (e.g. 'eu-west-1')" do
      stub = stub_request(:post, "#{base}/fn")
             .with(query: { "forceFunctionRegion" => "eu-west-1" })
             .to_return(status: 200, body: "")

      client.invoke("fn", region: "eu-west-1")
      expect(stub).to have_been_requested
    end
  end

  # ---------------------------------------------------------------------------
  # Response parsing
  # ---------------------------------------------------------------------------

  describe "response parsing" do
    it "auto-parses JSON when the response Content-Type says application/json" do
      stub_request(:post, "#{base}/fn").to_return(
        status:  200,
        body:    JSON.generate("ok" => true),
        headers: { "Content-Type" => "application/json" }
      )

      r = client.invoke("fn")
      expect(r.data).to eq("ok" => true)
    end

    it "returns the raw body when the Content-Type is not JSON (text/plain, etc.)" do
      stub_request(:post, "#{base}/fn").to_return(
        status:  200,
        body:    "hello world",
        headers: { "Content-Type" => "text/plain" }
      )

      r = client.invoke("fn")
      expect(r.data).to eq("hello world")
    end

    it "forces JSON parsing when response_type: :json is given (regardless of Content-Type)" do
      stub_request(:post, "#{base}/fn").to_return(
        status:  200,
        body:    JSON.generate(42),
        headers: { "Content-Type" => "text/plain" }
      )

      r = client.invoke("fn", response_type: :json)
      expect(r.data).to eq(42)
    end

    it "exposes the response status and headers on the Response struct" do
      stub_request(:post, "#{base}/fn").to_return(
        status:  201,
        body:    "",
        headers: { "X-Trace-Id" => "abc" }
      )

      r = client.invoke("fn")
      expect(r.status).to eq(201)
      expect(r.headers["x-trace-id"]).to eq("abc")
    end
  end

  # ---------------------------------------------------------------------------
  # Errors — HTTP vs Relay
  # ---------------------------------------------------------------------------

  describe "error handling" do
    it "raises FunctionsHttpError with the parsed 'error' field and HTTP status on a 4xx/5xx" do
      stub_request(:post, "#{base}/fn").to_return(
        status: 500,
        body:   JSON.generate("error" => "Boom inside the function")
      )

      expect { client.invoke("fn") }
        .to raise_error(Supabase::Functions::Errors::FunctionsHttpError) { |err|
          expect(err.message).to eq("Boom inside the function")
          expect(err.status).to eq(500)
        }
    end

    it "falls back to a synthetic message when the error body isn't JSON" do
      stub_request(:post, "#{base}/fn").to_return(status: 502, body: "Gateway")

      expect { client.invoke("fn") }
        .to raise_error(Supabase::Functions::Errors::FunctionsHttpError) { |err|
          expect(err.message).to include("error occurred")
          expect(err.status).to eq(502)
        }
    end

    it "raises FunctionsRelayError when x-relay-header is 'true' (relay-side failure)" do
      stub_request(:post, "#{base}/fn").to_return(
        status:  200, # relay errors can come back as 200 too
        body:    JSON.generate("error" => "Relay couldn't reach the function"),
        headers: { "x-relay-header" => "true" }
      )

      expect { client.invoke("fn") }
        .to raise_error(Supabase::Functions::Errors::FunctionsRelayError, /Relay couldn't reach/)
    end
  end
end
