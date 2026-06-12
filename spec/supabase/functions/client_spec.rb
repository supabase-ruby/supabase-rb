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
  # Invoke — body / headers
  # ---------------------------------------------------------------------------

  describe "#invoke" do
    it "POSTs to /<function_name> by default with the JSON body encoded" do
      stub_request(:post, "#{base}/hello")
        .with(body: JSON.generate("name" => "Ada"),
              headers: { "Content-Type" => "application/json", "Authorization" => "Bearer tok" })
        .to_return(status: 200, body: JSON.generate("ok" => true),
                   headers: { "Content-Type" => "application/json" })

      r = client.invoke("hello", body: { name: "Ada" }, response_type: :json)
      expect(r).to eq("ok" => true)
      expect(r).not_to be_a(Supabase::Functions::Types::Response)
    end

    it "sends a String body as text/plain without JSON-encoding it" do
      stub_request(:post, "#{base}/hello")
        .with(body: "raw payload",
              headers: { "Content-Type" => "text/plain" })
        .to_return(status: 200, body: "")

      client.invoke("hello", body: "raw payload")
    end

    it "doesn't add a Content-Type when the body is nil" do
      stub = stub_request(:post, "#{base}/ping")
             .with { |req| !req.headers.key?("Content-Type") || req.headers["Content-Type"] != "application/json" }
             .to_return(status: 200, body: "")

      client.invoke("ping")
      expect(stub).to have_been_requested
    end

    it "supports custom per-invocation headers (merged over client defaults)" do
      stub_request(:post, "#{base}/hello")
        .with(headers: { "X-Custom" => "header", "Authorization" => "Bearer tok" })
        .to_return(status: 200, body: "")

      client.invoke("hello", headers: { "X-Custom" => "header" })
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
    it "returns the raw body String even when the Content-Type is application/json (no auto-parse)" do
      stub_request(:post, "#{base}/fn").to_return(
        status:  200,
        body:    JSON.generate("ok" => true),
        headers: { "Content-Type" => "application/json" }
      )

      r = client.invoke("fn")
      expect(r).to be_a(String)
      expect(r).to eq(JSON.generate("ok" => true))
    end

    it "returns the raw body when the Content-Type is not JSON (text/plain, etc.)" do
      stub_request(:post, "#{base}/fn").to_return(
        status:  200,
        body:    "hello world",
        headers: { "Content-Type" => "text/plain" }
      )

      r = client.invoke("fn")
      expect(r).to eq("hello world")
    end

    it "parses JSON when response_type: :json is given (regardless of Content-Type)" do
      stub_request(:post, "#{base}/fn").to_return(
        status:  200,
        body:    JSON.generate(42),
        headers: { "Content-Type" => "text/plain" }
      )

      r = client.invoke("fn", response_type: :json)
      expect(r).to eq(42)
    end

    it "exposes the response status and headers on the Response struct when return_response: true" do
      allow(Kernel).to receive(:warn) # silence Types::Response deprecation warning
      stub_request(:post, "#{base}/fn").to_return(
        status:  201,
        body:    "",
        headers: { "X-Trace-Id" => "abc" }
      )

      r = client.invoke("fn", return_response: true)
      expect(r).to be_a(Supabase::Functions::Types::Response)
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

    it "raises FunctionsRelayError when x-relay-error is 'true' (relay-side failure)" do
      # supabase-js uses `x-relay-error`; py's `x-relay-header` is a bug not carried.
      stub_request(:post, "#{base}/fn").to_return(
        status:  200, # relay errors can come back as 200 too
        body:    JSON.generate("error" => "Relay couldn't reach the function"),
        headers: { "x-relay-error" => "true" }
      )

      expect { client.invoke("fn") }
        .to raise_error(Supabase::Functions::Errors::FunctionsRelayError, /Relay couldn't reach/)
    end
  end
end
