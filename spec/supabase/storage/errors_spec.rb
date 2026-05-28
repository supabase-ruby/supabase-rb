# frozen_string_literal: true

require "supabase/storage"

RSpec.describe Supabase::Storage::Errors do
  describe Supabase::Storage::Errors::StorageError do
    it "is a StandardError subclass" do
      expect(described_class.ancestors).to include(StandardError)
    end
  end

  describe Supabase::Storage::Errors::StorageApiError do
    it "captures message, code, and status from the Storage API response" do
      err = described_class.new("Bucket not found", code: "NotFound", status: 404)
      expect(err.message).to eq("Bucket not found")
      expect(err.code).to eq("NotFound")
      expect(err.status).to eq(404)
    end

    it "is a StorageError subclass so callers can rescue the umbrella" do
      expect(described_class.ancestors).to include(Supabase::Storage::Errors::StorageError)
    end

    it "round-trips through to_h with Python-style key names" do
      err = described_class.new("x", code: "C", status: 400)
      expect(err.to_h).to eq(
        "name" => "StorageApiError", "message" => "x", "code" => "C", "status" => 400
      )
    end
  end
end
