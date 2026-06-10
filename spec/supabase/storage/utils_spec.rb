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
    it "encodes spaces as %20 (RFC 3986), not '+' (form-urlencoded)" do
      expect(described_class.encode_segments(["folder", "file name with spaces.png"]))
        .to eq(["folder", "file%20name%20with%20spaces.png"])
    end

    it "encodes '+' as %2B so a literal plus survives a yarl-style server round-trip" do
      expect(described_class.encode_segments(["a+b.png"])).to eq(["a%2Bb.png"])
    end

    it "encodes '/' as %2F so a slash inside a single segment is preserved" do
      expect(described_class.encode_segments(["dir/with/slashes.png"])).to eq(["dir%2Fwith%2Fslashes.png"])
    end

    it "leaves the RFC 3986 unreserved set (ALPHA / DIGIT / -._~) untouched" do
      expect(described_class.encode_segments(["A-z.0_9~file"])).to eq(["A-z.0_9~file"])
    end

    it "encodes reserved characters" do
      expect(described_class.encode_segments(["a&b", "c?d"])).to eq(["a%26b", "c%3Fd"])
    end

    it "percent-encodes multi-byte UTF-8 byte-by-byte" do
      # "é" is C3 A9 in UTF-8 — must come out as %C3%A9, not %E9 (Latin-1).
      expect(described_class.encode_segments(["café.png"])).to eq(["caf%C3%A9.png"])
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
