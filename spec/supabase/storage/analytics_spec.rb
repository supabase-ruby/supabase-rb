# frozen_string_literal: true

require "supabase/storage"
require "webmock/rspec"
require "json"

RSpec.describe Supabase::Storage::AnalyticsClient do
  let(:base) { "https://x.supabase.co/storage/v1" }
  let(:headers) { { "apikey" => "anon", "Authorization" => "Bearer tok" } }
  let(:client) { Supabase::Storage::Client.new(base_url: base, headers: headers) }
  let(:analytics) { client.analytics }

  before { WebMock.disable_net_connect! }
  after  { WebMock.allow_net_connect! }

  it "is exposed off the storage client and memoized" do
    expect(analytics).to be_a(described_class)
    expect(client.analytics).to equal(analytics) # same instance on repeated access
  end

  describe "#create" do
    it "POSTs /iceberg/bucket with the bucket name and maps the result to AnalyticsBucket" do
      stub_request(:post, "#{base}/iceberg/bucket")
        .with(body: JSON.generate("name" => "warehouse"))
        .to_return(
          status:  200,
          body:    JSON.generate("name" => "warehouse", "type" => "ANALYTICS",
                                 "format" => "iceberg",
                                 "created_at" => "2026-01-01T00:00:00Z",
                                 "updated_at" => "2026-01-02T00:00:00Z"),
          headers: { "Content-Type" => "application/json" }
        )

      bucket = analytics.create("warehouse")
      expect(bucket).to be_a(Supabase::Storage::Types::AnalyticsBucket)
      expect(bucket.name).to eq("warehouse")
      expect(bucket.type).to eq("ANALYTICS")
    end
  end

  describe "#list" do
    it "GETs /iceberg/bucket with no query when no filters are passed" do
      stub_request(:get, "#{base}/iceberg/bucket")
        .to_return(status: 200, body: JSON.generate([{ "name" => "a", "type" => "ANALYTICS",
                                                       "created_at" => "t1", "updated_at" => "t1" }]))

      out = analytics.list
      expect(out.first.name).to eq("a")
    end

    it "drops nil filters before sending (mirrors py's `if v is not None` guard)" do
      stub_request(:get, "#{base}/iceberg/bucket")
        .with(query: { "limit" => "10", "sort_column" => "name" })
        .to_return(status: 200, body: JSON.generate([]))

      analytics.list(limit: 10, sort_column: "name", offset: nil, sort_order: nil, search: nil)
    end
  end

  describe "#delete" do
    it "DELETEs /iceberg/bucket/<name> and maps the response" do
      stub_request(:delete, "#{base}/iceberg/bucket/warehouse")
        .to_return(status: 200, body: JSON.generate("message" => "deleted"))

      out = analytics.delete("warehouse")
      expect(out).to be_a(Supabase::Storage::Types::AnalyticsBucketDeleteResponse)
      expect(out.message).to eq("deleted")
    end
  end

  describe "#catalog" do
    it "returns a config Hash with the storage URL, apiKey token, and S3 endpoint" do
      h = headers.merge("apiKey" => "service-key")
      c = Supabase::Storage::Client.new(base_url: base, headers: h).analytics

      cfg = c.catalog("warehouse", access_key_id: "AKIA", secret_access_key: "secret")
      expect(cfg["name"]).to eq("warehouse")
      expect(cfg["uri"]).to  eq("#{base}/iceberg/")
      expect(cfg["s3.endpoint"]).to eq("#{base}/s3")
      expect(cfg["s3.access-key-id"]).to eq("AKIA")
      expect(cfg["token"]).to eq("service-key")
    end

    it "raises when no apiKey is in the headers (py asserts it)" do
      expect { analytics.catalog("w", access_key_id: "k", secret_access_key: "s") }
        .to raise_error(Supabase::Storage::Errors::StorageApiError, /apiKey/)
    end
  end
end
