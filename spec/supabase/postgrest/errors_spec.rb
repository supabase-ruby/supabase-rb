# frozen_string_literal: true

require "supabase/postgrest"

RSpec.describe Supabase::Postgrest::Errors do
  FakeResponse = Struct.new(:status, :body) unless defined?(FakeResponse)

  describe Supabase::Postgrest::Errors::APIError do
    it "extracts message, code, hint, and details from a string-keyed hash" do
      err = described_class.new(
        "message" => "row not found",
        "code"    => "PGRST116",
        "hint"    => "Try a wider filter",
        "details" => "0 rows returned"
      )

      expect(err.message).to eq("row not found")
      expect(err.code).to    eq("PGRST116")
      expect(err.hint).to    eq("Try a wider filter")
      expect(err.details).to eq("0 rows returned")
    end

    it "accepts symbol-keyed hashes" do
      err = described_class.new(message: "boom", code: "500", hint: "h", details: "d")

      expect(err.message).to eq("boom")
      expect(err.code).to eq("500")
    end

    it "is a StandardError subclass that can be rescued" do
      expect { raise described_class.new("message" => "x") }
        .to raise_error(StandardError)
    end

    it "stringifies into a multi-line summary listing all populated fields" do
      err = described_class.new(
        "message" => "row not found",
        "code"    => "PGRST116",
        "hint"    => "Try a wider filter",
        "details" => "0 rows returned"
      )

      summary = err.to_s
      expect(summary).to include("Error PGRST116:")
      expect(summary).to include("Message: row not found")
      expect(summary).to include("Hint: Try a wider filter")
      expect(summary).to include("Details: 0 rows returned")
    end

    it "renders 'Empty error' when no fields are populated" do
      expect(described_class.new({}).to_s).to eq("Empty error")
    end

    it "exposes the original payload through #json and #raw" do
      payload = { "message" => "x", "errors" => [{ "code" => 400 }] }
      err = described_class.new(payload)

      expect(err.json).to eq(payload)
      expect(err.raw).to eq(payload)
    end

    it "defaults raw to {} when nil is passed in" do
      expect(described_class.new(nil).raw).to eq({})
    end

    it "always returns a String from #message, even for an empty payload" do
      expect(described_class.new({}).message).to be_a(String)
      expect(described_class.new(nil).message).to be_a(String)
      expect(described_class.new("code" => "PGRST116").message).to be_a(String)
    end

    it "accepts non-Hash payloads without raising and preserves the raw value" do
      err = described_class.new([1, 2, 3])

      expect(err.raw).to eq([1, 2, 3])
      expect(err.message).to include("[1, 2, 3]")
      expect(err.message).to eq("PostgREST returned non-hash error: [1, 2, 3]")
    end

    it "accepts a String payload without raising" do
      err = described_class.new("boom")

      expect(err.raw).to eq("boom")
      expect(err.message).to include('"boom"')
    end
  end

  describe ".generate_default_error_message" do
    it "synthesizes a payload from an HTTP response that wasn't valid JSON" do
      response = FakeResponse.new(502, "Gateway error")
      payload = described_class.generate_default_error_message(response)

      expect(payload).to eq(
        "message" => "JSON could not be generated",
        "code"    => "502",
        "hint"    => "Refer to full message for details",
        "details" => "Gateway error"
      )
    end
  end
end
