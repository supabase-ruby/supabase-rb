# frozen_string_literal: true

require "supabase/storage"

RSpec.describe Supabase::Storage::Types do
  describe "DEFAULT_SEARCH_OPTIONS" do
    it "matches storage3's default body for the list() endpoint" do
      expect(described_class::DEFAULT_SEARCH_OPTIONS).to eq(
        "limit"  => 100,
        "offset" => 0,
        "sortBy" => { "column" => "name", "order" => "asc" }
      )
    end

    it "is frozen so accidental mutation can't leak across requests" do
      expect(described_class::DEFAULT_SEARCH_OPTIONS).to be_frozen
    end
  end

  describe "DEFAULT_FILE_OPTIONS" do
    it "carries the canonical cache-control / content-type / x-upsert defaults" do
      expect(described_class::DEFAULT_FILE_OPTIONS).to eq(
        "cache-control" => "3600",
        "content-type"  => "text/plain;charset=UTF-8",
        "x-upsert"      => "false"
      )
    end
  end

  describe described_class::Bucket do
    it "builds from a string-keyed hash" do
      b = described_class.from_hash(
        "id" => "avatars", "name" => "avatars", "owner" => "u1",
        "public" => true, "file_size_limit" => 1024, "allowed_mime_types" => ["image/png"],
        "created_at" => "t1", "updated_at" => "t2", "type" => "STANDARD"
      )
      expect(b.id).to eq("avatars")
      expect(b.public).to be true
      expect(b.allowed_mime_types).to eq(["image/png"])
    end

    it "returns nil when given nil (so list_buckets can map blind)" do
      expect(described_class.from_hash(nil)).to be_nil
    end

    it "accepts symbol-keyed hashes too" do
      b = described_class.from_hash(id: "a", name: "a", public: false)
      expect(b.id).to eq("a")
      expect(b.public).to be false
    end
  end

  describe described_class::UploadResponse do
    it "aliases full_path as fullPath for Python-style callers" do
      r = described_class.from_hash(path: "f/x.png", key: "avatars/f/x.png")
      expect(r.path).to eq("f/x.png")
      expect(r.full_path).to eq("avatars/f/x.png")
      expect(r.fullPath).to eq("avatars/f/x.png")
      expect(r.key).to eq("avatars/f/x.png")
    end
  end

  describe described_class::SignedUploadURL do
    it "aliases signed_url as signedUrl" do
      s = described_class.new(signed_url: "https://x/u", token: "t", path: "f/x.png")
      expect(s.signedUrl).to eq("https://x/u")
    end
  end
end
