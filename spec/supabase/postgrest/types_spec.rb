# frozen_string_literal: true

require "supabase/postgrest"

RSpec.describe Supabase::Postgrest::Types do
  describe Supabase::Postgrest::Types::CountMethod do
    it "defines the three PostgREST count strategies" do
      expect(described_class::EXACT).to eq("exact")
      expect(described_class::PLANNED).to eq("planned")
      expect(described_class::ESTIMATED).to eq("estimated")
      expect(described_class::ALL).to contain_exactly("exact", "planned", "estimated")
    end
  end

  describe Supabase::Postgrest::Types::ReturnMethod do
    it "defines minimal and representation return modes" do
      expect(described_class::MINIMAL).to eq("minimal")
      expect(described_class::REPRESENTATION).to eq("representation")
    end
  end

  describe Supabase::Postgrest::Types::RequestMethod do
    it "defines the HTTP verbs PostgREST uses" do
      expect(described_class::GET).to eq("GET")
      expect(described_class::POST).to eq("POST")
      expect(described_class::PATCH).to eq("PATCH")
      expect(described_class::PUT).to eq("PUT")
      expect(described_class::DELETE).to eq("DELETE")
      expect(described_class::HEAD).to eq("HEAD")
    end
  end

  describe Supabase::Postgrest::Types::Filters do
    it "matches the supabase-py operator set 1:1" do
      expected = {
        "NOT" => "not", "EQ" => "eq", "NEQ" => "neq",
        "GT"  => "gt",  "GTE" => "gte", "LT"  => "lt", "LTE" => "lte",
        "IS"  => "is",
        "LIKE" => "like", "LIKE_ALL" => "like(all)", "LIKE_ANY" => "like(any)",
        "ILIKE" => "ilike", "ILIKE_ALL" => "ilike(all)", "ILIKE_ANY" => "ilike(any)",
        "FTS" => "fts", "PLFTS" => "plfts", "PHFTS" => "phfts", "WFTS" => "wfts",
        "IN" => "in", "CS" => "cs", "CD" => "cd", "OV" => "ov",
        "SL" => "sl", "SR" => "sr", "NXL" => "nxl", "NXR" => "nxr", "ADJ" => "adj"
      }

      expected.each do |const_name, value|
        expect(described_class.const_get(const_name)).to eq(value)
      end
    end
  end
end
