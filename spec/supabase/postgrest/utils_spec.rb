# frozen_string_literal: true

require "supabase/postgrest"

RSpec.describe Supabase::Postgrest::Utils do
  describe ".sanitize_param" do
    it "returns the value unchanged when no reserved characters are present" do
      expect(described_class.sanitize_param("hello")).to eq("hello")
    end

    it "quotes values that contain a comma" do
      expect(described_class.sanitize_param("a,b")).to eq(%("a,b"))
    end

    it "quotes values that contain a colon" do
      expect(described_class.sanitize_param("name:thing")).to eq(%("name:thing"))
    end

    it "quotes values that contain parentheses" do
      expect(described_class.sanitize_param("foo(bar)")).to eq(%("foo(bar)"))
    end

    it "coerces non-string inputs via to_s" do
      expect(described_class.sanitize_param(42)).to eq("42")
      expect(described_class.sanitize_param(:status)).to eq("status")
    end
  end

  describe ".sanitize_pattern_param" do
    it "converts SQL '%' wildcards into PostgREST '*' before sanitizing" do
      expect(described_class.sanitize_pattern_param("%abc%")).to eq("*abc*")
    end

    it "still quotes patterns that contain reserved characters after substitution" do
      expect(described_class.sanitize_pattern_param("%a,b%")).to eq(%("*a,b*"))
    end
  end
end
