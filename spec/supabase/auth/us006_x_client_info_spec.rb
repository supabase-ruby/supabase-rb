# frozen_string_literal: true

require "spec_helper"
require "faraday"
require "json"

# US-006 / M-10: Auth client must tag every outbound request with `X-Client-Info`
# for tracing parity with supabase-py. The default value comes from
# Supabase::Auth::Constants::DEFAULT_HEADERS and must reach Faraday on the wire.
RSpec.describe "US-006: Auth client sends X-Client-Info on every request" do
  let(:base_url) { "http://localhost:9999" }

  def build_client(headers: {}, &stub_block)
    stubs = Faraday::Adapter::Test::Stubs.new(&stub_block)
    conn = Faraday.new(url: base_url) do |f|
      f.response :raise_error
      f.adapter :test, stubs
    end
    client = Supabase::Auth::Client.new(url: base_url, headers: headers, http_client: conn)
    [client, stubs]
  end

  it "sends X-Client-Info from Constants on sign_in_with_password" do
    captured = nil
    client, stubs = build_client do |stub|
      stub.post("/token") do |env|
        captured = env.request_headers
        [200, { "Content-Type" => "application/json" }, "{}"]
      end
    end

    client.sign_in_with_password(email: "a@b.com", password: "secret")
    stubs.verify_stubbed_calls

    expect(captured["X-Client-Info"]).to eq(Supabase::Auth::Constants::DEFAULT_HEADERS["X-Client-Info"])
    expect(captured["X-Client-Info"]).to match(%r{\Agotrue-rb/})
  end

  it "sends X-Client-Info on sign_up" do
    captured = nil
    client, stubs = build_client do |stub|
      stub.post("/signup") do |env|
        captured = env.request_headers
        [200, { "Content-Type" => "application/json" }, "{}"]
      end
    end

    client.sign_up(email: "a@b.com", password: "secret")
    stubs.verify_stubbed_calls

    expect(captured["X-Client-Info"]).to match(%r{\Agotrue-rb/})
  end

  it "sends X-Client-Info on get_user (GET requests, not just POST)" do
    captured = nil
    client, stubs = build_client do |stub|
      stub.get("/user") do |env|
        captured = env.request_headers
        [200, { "Content-Type" => "application/json" }, '{"id": "u-1"}']
      end
    end

    client.get_user("some-jwt")
    stubs.verify_stubbed_calls

    expect(captured["X-Client-Info"]).to match(%r{\Agotrue-rb/})
  end

  it "sends X-Client-Info alongside any caller-supplied default headers" do
    captured = nil
    client, stubs = build_client(headers: { "apikey" => "anon-key" }) do |stub|
      stub.post("/token") do |env|
        captured = env.request_headers
        [200, { "Content-Type" => "application/json" }, "{}"]
      end
    end

    client.sign_in_with_password(email: "a@b.com", password: "secret")
    stubs.verify_stubbed_calls

    expect(captured["apikey"]).to eq("anon-key")
    expect(captured["X-Client-Info"]).to match(%r{\Agotrue-rb/})
  end

  it "lets the caller override X-Client-Info on the wire" do
    captured = nil
    client, stubs = build_client(headers: { "X-Client-Info" => "umbrella/9.9.9" }) do |stub|
      stub.post("/token") do |env|
        captured = env.request_headers
        [200, { "Content-Type" => "application/json" }, "{}"]
      end
    end

    client.sign_in_with_password(email: "a@b.com", password: "secret")
    stubs.verify_stubbed_calls

    expect(captured["X-Client-Info"]).to eq("umbrella/9.9.9")
  end
end
