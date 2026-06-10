# frozen_string_literal: true

require "supabase/functions"
require "webmock/rspec"
require "json"

# US-026 / F-C11 — part 1.
#
# `Supabase::Functions::Client#invoke` returns the parsed body directly
# (Hash / String / Array / nil), not the `Types::Response` wrapper. The
# legacy wrapper survives behind `return_response: true` and is marked
# deprecated — the first construction of `Types::Response` emits a one-time
# warning.
RSpec.describe Supabase::Functions::Client, "US-026: invoke returns data directly" do
  let(:base)   { "https://x.supabase.co/functions/v1" }
  let(:client) do
    described_class.new(
      base_url: base,
      headers:  { "Authorization" => "Bearer tok", "apikey" => "anon" }
    )
  end

  before do
    WebMock.disable_net_connect!
    # Reset the one-time warning flag so each example can independently assert
    # whether `Types::Response.new` emitted a warning in its own context.
    Supabase::Functions::Types::Response._deprecation_warned = false
  end
  after { WebMock.allow_net_connect! }

  # ---------------------------------------------------------------------------
  # AC #1, #4: invoke returns String / Hash directly, not Types::Response
  # ---------------------------------------------------------------------------

  describe "default return shape" do
    it "returns the parsed JSON Hash directly (not a Types::Response wrapper)" do
      allow(Kernel).to receive(:warn) # any leaked Response.new must not pollute stderr

      stub_request(:post, "#{base}/hello")
        .to_return(status: 200, body: JSON.generate("greeting" => "hi"),
                   headers: { "Content-Type" => "application/json" })

      result = client.invoke("hello", body: { name: "Ada" })

      expect(result).to be_a(Hash)
      expect(result).to eq("greeting" => "hi")
      expect(result).not_to be_a(Supabase::Functions::Types::Response)
    end

    it "returns a raw String directly when the response is text/plain" do
      allow(Kernel).to receive(:warn)

      stub_request(:post, "#{base}/fn")
        .to_return(status: 200, body: "hello world",
                   headers: { "Content-Type" => "text/plain" })

      result = client.invoke("fn")

      expect(result).to be_a(String)
      expect(result).to eq("hello world")
      expect(result).not_to be_a(Supabase::Functions::Types::Response)
    end

    it "returns an Array directly when the response is a JSON array" do
      allow(Kernel).to receive(:warn)

      stub_request(:post, "#{base}/fn")
        .to_return(status: 200, body: JSON.generate([1, 2, 3]),
                   headers: { "Content-Type" => "application/json" })

      result = client.invoke("fn")

      expect(result).to eq([1, 2, 3])
    end

    it "does NOT instantiate Types::Response on the default path (no deprecation warning fired)" do
      stub_request(:post, "#{base}/fn")
        .to_return(status: 200, body: JSON.generate("ok" => true),
                   headers: { "Content-Type" => "application/json" })

      expect(Kernel).not_to receive(:warn)

      client.invoke("fn")
      expect(Supabase::Functions::Types::Response._deprecation_warned).to be_falsey
    end
  end

  # ---------------------------------------------------------------------------
  # AC #2: return_response: true keeps the legacy wrapper available
  # ---------------------------------------------------------------------------

  describe "return_response: true (compatibility kwarg)" do
    before { allow(Kernel).to receive(:warn) } # silence the deprecation warning

    it "returns the deprecated Types::Response wrapper with data/status/headers" do
      stub_request(:post, "#{base}/fn")
        .to_return(status: 201, body: JSON.generate("ok" => true),
                   headers: { "Content-Type" => "application/json", "X-Trace-Id" => "abc" })

      result = client.invoke("fn", return_response: true)

      expect(result).to be_a(Supabase::Functions::Types::Response)
      expect(result.data).to eq("ok" => true)
      expect(result.status).to eq(201)
      expect(result.headers["x-trace-id"]).to eq("abc")
    end

    it "wraps a raw String body inside Types::Response#data when return_response: true" do
      stub_request(:post, "#{base}/fn")
        .to_return(status: 200, body: "raw",
                   headers: { "Content-Type" => "text/plain" })

      result = client.invoke("fn", return_response: true)

      expect(result).to be_a(Supabase::Functions::Types::Response)
      expect(result.data).to eq("raw")
      expect(result.status).to eq(200)
    end
  end

  # ---------------------------------------------------------------------------
  # AC #3: Types::Response carries a deprecation warning (once-per-process)
  # ---------------------------------------------------------------------------

  describe "Types::Response deprecation warning" do
    it "emits a deprecation warning the first time Types::Response.new is called" do
      expect(Kernel).to receive(:warn).with(/deprecat/i).once

      Supabase::Functions::Types::Response.new(data: 1, status: 200, headers: {})
    end

    it "does not repeat the warning on subsequent constructions in the same process" do
      expect(Kernel).to receive(:warn).with(/deprecat/i).once

      Supabase::Functions::Types::Response.new(data: 1, status: 200, headers: {})
      Supabase::Functions::Types::Response.new(data: 2, status: 200, headers: {})
      Supabase::Functions::Types::Response.new(data: 3, status: 200, headers: {})
    end

    it "fires the warning when invoke(..., return_response: true) is used" do
      stub_request(:post, "#{base}/fn").to_return(status: 200, body: "{}",
                                                  headers: { "Content-Type" => "application/json" })

      expect(Kernel).to receive(:warn).with(/deprecat/i).once

      client.invoke("fn", return_response: true)
    end

    it "carries a message that names the replacement (return_response or reading data directly)" do
      message_seen = nil
      allow(Kernel).to receive(:warn) { |msg| message_seen = msg }

      Supabase::Functions::Types::Response.new(data: 1, status: 200, headers: {})

      expect(message_seen).to include("Supabase::Functions::Types::Response")
      expect(message_seen).to match(/return_response|directly/i)
    end
  end
end
