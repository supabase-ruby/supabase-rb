# frozen_string_literal: true

require "supabase/functions"
require "webmock/rspec"
require "json"

# US-027 / F-C11 — part 2.
#
# JSON is parsed *only* when the caller opts in via `response_type: :json`.
# This matches supabase-py — the Content-Type header is never consulted to
# infer parsing (that's the supabase-js behavior, deliberately not ported).
#
# AC:
#   1. By default `invoke` returns raw bytes / String.
#   2. `response_type: "json"` → JSON parsing.
#   3. Spec: invoke without `response_type` against a JSON server → String.
#   4. Spec: invoke with `response_type: "json"` → Hash.
RSpec.describe Supabase::Functions::Client, "US-027: invoke JSON parse only when response_type=:json" do
  let(:base)   { "https://x.supabase.co/functions/v1" }
  let(:client) do
    described_class.new(
      base_url: base,
      headers:  { "Authorization" => "Bearer tok", "apikey" => "anon" }
    )
  end

  before { WebMock.disable_net_connect! }
  after  { WebMock.allow_net_connect! }

  # ---------------------------------------------------------------------------
  # AC #1, #3: default invoke returns the raw response body as a String — even
  # when the server claims application/json. No Content-Type sniffing.
  # ---------------------------------------------------------------------------

  describe "default (no response_type)" do
    it "returns the raw String body against an application/json server (AC #3)" do
      json_body = JSON.generate("greeting" => "hi Ada")
      stub_request(:post, "#{base}/hello")
        .to_return(status: 200, body: json_body,
                   headers: { "Content-Type" => "application/json" })

      result = client.invoke("hello", body: { name: "Ada" })

      expect(result).to be_a(String)
      expect(result).to eq(json_body)
      expect(result).not_to be_a(Hash)
    end

    it "returns the raw String body for text/plain responses" do
      stub_request(:post, "#{base}/fn")
        .to_return(status: 200, body: "plain text",
                   headers: { "Content-Type" => "text/plain" })

      result = client.invoke("fn")

      expect(result).to be_a(String)
      expect(result).to eq("plain text")
    end

    it "returns the raw String body when the server omits Content-Type entirely" do
      stub_request(:post, "#{base}/fn")
        .to_return(status: 200, body: JSON.generate("x" => 1))

      result = client.invoke("fn")

      expect(result).to be_a(String)
      expect(result).to eq(JSON.generate("x" => 1))
    end
  end

  # ---------------------------------------------------------------------------
  # AC #2, #4: response_type: :json (or "json") parses the body to a Hash/Array.
  # ---------------------------------------------------------------------------

  describe "response_type: :json (opt-in)" do
    it "parses the JSON body into a Hash (AC #4)" do
      stub_request(:post, "#{base}/hello")
        .to_return(status: 200, body: JSON.generate("greeting" => "hi Ada"),
                   headers: { "Content-Type" => "application/json" })

      result = client.invoke("hello", body: { name: "Ada" }, response_type: :json)

      expect(result).to be_a(Hash)
      expect(result).to eq("greeting" => "hi Ada")
    end

    it "accepts the String form 'json' (parity with the Symbol form)" do
      stub_request(:post, "#{base}/hello")
        .to_return(status: 200, body: JSON.generate("ok" => true),
                   headers: { "Content-Type" => "application/json" })

      result = client.invoke("hello", response_type: "json")

      expect(result).to eq("ok" => true)
    end

    it "parses JSON even when the server returns text/plain (caller opt-in wins)" do
      stub_request(:post, "#{base}/fn")
        .to_return(status: 200, body: JSON.generate(42),
                   headers: { "Content-Type" => "text/plain" })

      expect(client.invoke("fn", response_type: :json)).to eq(42)
    end

    it "parses a JSON Array into an Array" do
      stub_request(:post, "#{base}/fn")
        .to_return(status: 200, body: JSON.generate([1, 2, 3]),
                   headers: { "Content-Type" => "application/json" })

      expect(client.invoke("fn", response_type: :json)).to eq([1, 2, 3])
    end
  end

  # ---------------------------------------------------------------------------
  # Regression guard: Content-Type alone must NEVER trigger parsing. Pinned
  # explicitly so a future "auto-parse via Content-Type" patch fails loudly.
  # ---------------------------------------------------------------------------

  describe "Content-Type sniffing is intentionally disabled" do
    it "does not parse JSON when Content-Type is application/json but response_type is unset" do
      stub_request(:post, "#{base}/fn")
        .to_return(status: 200, body: JSON.generate("x" => 1),
                   headers: { "Content-Type" => "application/json; charset=utf-8" })

      result = client.invoke("fn")
      expect(result).to be_a(String)
    end

    it "does not parse JSON for a non-json response_type value (e.g. :text)" do
      stub_request(:post, "#{base}/fn")
        .to_return(status: 200, body: JSON.generate("x" => 1),
                   headers: { "Content-Type" => "application/json" })

      result = client.invoke("fn", response_type: :text)
      expect(result).to be_a(String)
      expect(result).to eq(JSON.generate("x" => 1))
    end
  end
end
