# frozen_string_literal: true

require "supabase/functions"

RSpec.describe Supabase::Functions::Types do
  describe described_class::Response do
    it "is a Struct exposing data / status / headers" do
      r = described_class.new(data: { "ok" => true }, status: 200, headers: { "x" => "y" })
      expect(r.data).to eq("ok" => true)
      expect(r.status).to eq(200)
      expect(r.headers).to eq("x" => "y")
    end
  end

  describe described_class::FunctionRegion do
    it "covers the 15 documented Edge Function regions" do
      expect(described_class::ALL.length).to eq(15)
    end

    it "defines a canonical 'any' constant alongside named regions" do
      expect(described_class::ANY).to eq("any")
      expect(described_class::US_EAST_1).to eq("us-east-1")
      expect(described_class::EU_WEST_2).to eq("eu-west-2")
    end

    it "uses lowercase-hyphen strings (matches the x-region header values)" do
      described_class::ALL.each do |r|
        expect(r).to match(/\A[a-z0-9-]+\z/)
      end
    end
  end
end
