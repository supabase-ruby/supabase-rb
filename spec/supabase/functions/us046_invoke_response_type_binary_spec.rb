# frozen_string_literal: true

require "supabase/functions"
require "webmock/rspec"
require "json"

# US-046 — `response_type: :binary` returns the response body byte-for-byte as
# a `String` with `Encoding::BINARY` (ASCII-8BIT). `:text` keeps the default
# `Encoding::UTF_8`. `:json` is unchanged.
#
# Ruby always returns a `String` — unlike supabase-py, which returns `bytes`
# for binary. The encoding flag is the only thing that varies between
# `:text` and `:binary`.
RSpec.describe Supabase::Functions::Client, "US-046: invoke response_type: :binary" do
  let(:base) { "https://x.supabase.co/functions/v1" }
  let(:client) do
    described_class.new(
      base_url: base,
      headers:  { "Authorization" => "Bearer tok", "apikey" => "anon" }
    )
  end

  before { WebMock.disable_net_connect! }
  after  { WebMock.allow_net_connect! }

  describe "response_type: :binary" do
    it "returns binary response body byte-for-byte" do
      raw = (0..255).map(&:chr).join.b # every byte value 0..255, ASCII-8BIT
      stub_request(:post, "#{base}/fn")
        .to_return(status: 200, body: raw,
                   headers: { "Content-Type" => "application/octet-stream" })

      result = client.invoke("fn", response_type: :binary)

      expect(result).to be_a(String)
      expect(result.encoding).to eq(Encoding::BINARY)
      expect(result.bytes).to eq(raw.bytes)
      expect(result.bytesize).to eq(256)
    end

    it "accepts the String form 'binary' (parity with the Symbol form)" do
      raw = "\xFF\xFE\x00\x01".b
      stub_request(:post, "#{base}/fn")
        .to_return(status: 200, body: raw)

      result = client.invoke("fn", response_type: "binary")

      expect(result.encoding).to eq(Encoding::BINARY)
      expect(result.bytes).to eq(raw.bytes)
    end

    it "preserves bytes even when the server tags the response as text/plain" do
      raw = "\x89PNG\r\n\x1A\n".b # PNG magic bytes — not valid UTF-8
      stub_request(:post, "#{base}/fn")
        .to_return(status: 200, body: raw,
                   headers: { "Content-Type" => "text/plain" })

      result = client.invoke("fn", response_type: :binary)

      expect(result.encoding).to eq(Encoding::BINARY)
      expect(result.bytes).to eq(raw.bytes)
    end

    it "returns an empty BINARY String when the body is empty" do
      stub_request(:post, "#{base}/fn").to_return(status: 200, body: "")

      result = client.invoke("fn", response_type: :binary)

      expect(result).to be_a(String)
      expect(result.encoding).to eq(Encoding::BINARY)
      expect(result).to be_empty
    end

    it "returns a fresh String — not the underlying Faraday body" do
      stub_request(:post, "#{base}/fn").to_return(status: 200, body: "hello")

      a = client.invoke("fn", response_type: :binary)
      b = client.invoke("fn", response_type: :binary)

      # Two independent calls must not share a String — mutating one of them
      # would otherwise leak across invocations. Guards against returning the
      # Faraday-owned body directly.
      expect(a).not_to equal(b)
    end
  end

  describe "response_type: :text" do
    it "returns text response with UTF-8 encoding" do
      stub_request(:post, "#{base}/fn")
        .to_return(status: 200, body: "café au lait",
                   headers: { "Content-Type" => "text/plain; charset=utf-8" })

      result = client.invoke("fn", response_type: :text)

      expect(result).to be_a(String)
      expect(result.encoding).to eq(Encoding::UTF_8)
      expect(result).to eq("café au lait")
    end

    it "is the default response_type (omitting the kwarg matches :text)" do
      stub_request(:post, "#{base}/fn").to_return(status: 200, body: "hello")

      result = client.invoke("fn")

      expect(result).to be_a(String)
      expect(result.encoding).to eq(Encoding::UTF_8)
      expect(result).to eq("hello")
    end
  end

  describe "response_type: :json (regression guard)" do
    it "still parses JSON into a Hash unchanged" do
      stub_request(:post, "#{base}/fn")
        .to_return(status: 200, body: JSON.generate("ok" => true),
                   headers: { "Content-Type" => "application/json" })

      expect(client.invoke("fn", response_type: :json)).to eq("ok" => true)
    end

    it "still parses JSON arrays unchanged" do
      stub_request(:post, "#{base}/fn")
        .to_return(status: 200, body: JSON.generate([1, 2, 3]))

      expect(client.invoke("fn", response_type: :json)).to eq([1, 2, 3])
    end
  end
end
