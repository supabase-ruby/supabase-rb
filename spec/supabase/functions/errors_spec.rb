# frozen_string_literal: true

require "supabase/functions"

RSpec.describe Supabase::Functions::Errors do
  describe Supabase::Functions::Errors::FunctionsError do
    it "captures message, name, and status" do
      err = described_class.new("boom", name: "FunctionsError", status: 500)
      expect(err.message).to eq("boom")
      expect(err.name).to eq("FunctionsError")
      expect(err.status).to eq(500)
    end

    it "is a StandardError so callers can rescue broadly" do
      expect(described_class.ancestors).to include(StandardError)
    end

    it "round-trips through to_h with Python-style key names" do
      err = described_class.new("boom", name: "FunctionsError", status: 500)
      expect(err.to_h).to eq("name" => "FunctionsError", "message" => "boom", "status" => 500)
    end
  end

  describe Supabase::Functions::Errors::FunctionsHttpError do
    it "tags itself with name 'FunctionsHttpError' and defaults status to 400" do
      err = described_class.new("bad")
      expect(err.name).to eq("FunctionsHttpError")
      expect(err.status).to eq(400)
    end

    it "honors an explicit status:" do
      expect(described_class.new("bad", status: 503).status).to eq(503)
    end
  end

  describe Supabase::Functions::Errors::FunctionsRelayError do
    it "tags itself with name 'FunctionsRelayError'" do
      err = described_class.new("relay down")
      expect(err.name).to eq("FunctionsRelayError")
      expect(err.status).to eq(400)
    end
  end
end
