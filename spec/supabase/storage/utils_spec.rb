# frozen_string_literal: true

require "supabase/storage"

RSpec.describe Supabase::Storage::Utils do
  describe ".relative_path_to_parts" do
    it "splits a slash-delimited path into segments" do
      expect(described_class.relative_path_to_parts("folder/avatar.png"))
        .to eq(%w[folder avatar.png])
    end

    it "drops a leading slash if present (so callers can pass either form)" do
      expect(described_class.relative_path_to_parts("/folder/x.png"))
        .to eq(%w[folder x.png])
    end

    it "returns [] for nil or empty input" do
      expect(described_class.relative_path_to_parts(nil)).to eq([])
      expect(described_class.relative_path_to_parts("")).to eq([])
    end
  end

  describe ".encode_segments" do
    it "URL-encodes user-supplied path segments so funky filenames don't break URLs" do
      expect(described_class.encode_segments(["folder", "file name with spaces.png"]))
        .to eq(["folder", "file+name+with+spaces.png"])
    end

    it "encodes reserved characters" do
      expect(described_class.encode_segments(["a&b", "c?d"])).to eq(["a%26b", "c%3Fd"])
    end
  end

  describe ".join_url" do
    it "concatenates the base URL with encoded segments" do
      expect(described_class.join_url("https://x.co/v1/", ["bucket", "id"]))
        .to eq("https://x.co/v1/bucket/id")
    end

    it "appends a query string when one is supplied" do
      expect(described_class.join_url("https://x.co/v1", %w[a b], "k" => "v"))
        .to eq("https://x.co/v1/a/b?k=v")
    end

    it "ignores an empty or nil query" do
      expect(described_class.join_url("https://x.co/v1", %w[a], nil)).to eq("https://x.co/v1/a")
      expect(described_class.join_url("https://x.co/v1", %w[a], {})).to eq("https://x.co/v1/a")
    end
  end
end
