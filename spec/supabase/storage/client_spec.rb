# frozen_string_literal: true

require "supabase/storage"

RSpec.describe Supabase::Storage::Client do
  describe "#initialize" do
    it "ensures the base URL ends with a trailing slash so URL joining is unambiguous" do
      c = described_class.new(base_url: "https://x.supabase.co/storage/v1")
      expect(c.base_url).to eq("https://x.supabase.co/storage/v1/")

      c2 = described_class.new(base_url: "https://x.supabase.co/storage/v1/")
      expect(c2.base_url).to eq("https://x.supabase.co/storage/v1/")
    end

    it "stamps the X-Client-Info header so the API can identify the gem version" do
      c = described_class.new(base_url: "https://x/v1", headers: { "apikey" => "k" })
      expect(c.headers["X-Client-Info"]).to match(%r{supabase-rb/storage-rb v})
      expect(c.headers["apikey"]).to eq("k")
    end
  end

  describe "#from / #bucket" do
    let(:client) { described_class.new(base_url: "https://x/v1") }

    it "returns a FileApi scoped to the given bucket id" do
      file = client.from("avatars")
      expect(file).to be_a(Supabase::Storage::FileApi)
      expect(file.id).to eq("avatars")
    end

    it "exposes #bucket as an alias of #from" do
      expect(client.method(:bucket)).to eq(client.method(:from))
    end
  end
end
