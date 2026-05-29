# frozen_string_literal: true

require "supabase/storage"
require "webmock/rspec"
require "json"

RSpec.describe Supabase::Storage::VectorsClient do
  let(:base) { "https://x.supabase.co/storage/v1" }
  let(:headers) { { "apikey" => "anon", "Authorization" => "Bearer tok" } }
  let(:client) { Supabase::Storage::Client.new(base_url: base, headers: headers) }
  let(:vectors) { client.vectors }

  before { WebMock.disable_net_connect! }
  after  { WebMock.allow_net_connect! }

  it "is exposed off the storage client and memoized" do
    expect(vectors).to be_a(described_class)
    expect(client.vectors).to equal(vectors)
  end

  # ---------------------------------------------------------------------------
  # Bucket operations
  # ---------------------------------------------------------------------------

  describe "#create_bucket" do
    it "POSTs CreateVectorBucket with the vectorBucketName" do
      stub_request(:post, "#{base}/vector/CreateVectorBucket")
        .with(body: JSON.generate("vectorBucketName" => "docs"))
        .to_return(status: 200, body: "")

      expect(vectors.create_bucket("docs")).to be_nil
    end
  end

  describe "#get_bucket" do
    it "returns a wrapped response on success" do
      stub_request(:post, "#{base}/vector/GetVectorBucket")
        .to_return(
          status: 200,
          body:   JSON.generate("vectorBucket" => { "vectorBucketName" => "docs" }),
          headers: { "Content-Type" => "application/json" }
        )

      r = vectors.get_bucket("docs")
      expect(r.vector_bucket.vector_bucket_name).to eq("docs")
    end

    it "returns nil when the API reports the bucket is missing (mirrors py's StorageApiError swallow)" do
      stub_request(:post, "#{base}/vector/GetVectorBucket")
        .to_return(status: 404, body: JSON.generate("message" => "not found", "error" => "NotFound", "statusCode" => 404))

      expect(vectors.get_bucket("missing")).to be_nil
    end
  end

  describe "#list_buckets" do
    it "drops nil filters before sending" do
      stub_request(:post, "#{base}/vector/ListVectorBuckets")
        .with(body: JSON.generate("prefix" => "x"))
        .to_return(status: 200, body: JSON.generate("vectorBuckets" => [{ "vectorBucketName" => "xa" }]))

      out = vectors.list_buckets(prefix: "x")
      expect(out.vector_buckets.first[:name]).to eq("xa")
    end
  end

  describe "#delete_bucket" do
    it "POSTs DeleteVectorBucket" do
      stub_request(:post, "#{base}/vector/DeleteVectorBucket")
        .with(body: JSON.generate("vectorBucketName" => "docs"))
        .to_return(status: 200, body: "")
      vectors.delete_bucket("docs")
    end
  end

  # ---------------------------------------------------------------------------
  # Bucket-scoped (index management)
  # ---------------------------------------------------------------------------

  describe "VectorBucketScope" do
    let(:scope) { vectors.from("docs") }

    it "#create_index POSTs CreateIndex with the bucket name stamped in" do
      expected = JSON.parse(JSON.generate(
        "vectorBucketName" => "docs",
        "indexName"        => "paragraphs",
        "dimension"        => 1536,
        "distanceMetric"   => "cosine",
        "dataType"         => "float32"
      ))
      stub_request(:post, "#{base}/vector/CreateIndex")
        .with { |req| JSON.parse(req.body) == expected }
        .to_return(status: 200, body: "")

      scope.create_index("paragraphs", 1536, "cosine", "float32")
    end

    it "#get_index returns nil on a StorageApiError" do
      stub_request(:post, "#{base}/vector/GetIndex")
        .to_return(status: 404, body: JSON.generate("message" => "no", "error" => "NotFound", "statusCode" => 404))

      expect(scope.get_index("p")).to be_nil
    end

    it "#list_indexes hits ListIndexes and maps to a response wrapper" do
      stub_request(:post, "#{base}/vector/ListIndexes")
        .to_return(status: 200, body: JSON.generate("indexes" => [{ "indexName" => "p" }], "nextToken" => "tok"))

      r = scope.list_indexes
      expect(r.indexes.first[:index_name]).to eq("p")
      expect(r.next_token).to eq("tok")
    end

    it "#delete_index hits DeleteIndex" do
      stub_request(:post, "#{base}/vector/DeleteIndex")
        .with(body: JSON.generate("vectorBucketName" => "docs", "indexName" => "p"))
        .to_return(status: 200, body: "")
      scope.delete_index("p")
    end
  end

  # ---------------------------------------------------------------------------
  # Index-scoped (record CRUD + query)
  # ---------------------------------------------------------------------------

  describe "VectorIndexScope" do
    let(:idx) { vectors.from("docs").index("paragraphs") }

    it "#put stamps bucket+index and posts PutVectors" do
      stub_request(:post, "#{base}/vector/PutVectors").to_return(status: 200, body: "")
      idx.put([{ key: "p1", data: { float32: [0.1, 0.2] } }])
    end

    it "#get posts GetVectors with keys" do
      stub_request(:post, "#{base}/vector/GetVectors")
        .to_return(status: 200, body: JSON.generate("vectors" => [{ "key" => "p1", "distance" => 0.1 }]))

      r = idx.get("p1", "p2")
      expect(r.vectors.first.key).to eq("p1")
    end

    it "#query posts QueryVectors and parses VectorMatch records" do
      stub_request(:post, "#{base}/vector/QueryVectors")
        .to_return(status: 200, body: JSON.generate("vectors" => [{ "key" => "p1", "distance" => 0.05 }]))

      r = idx.query({ float32: [0.0] }, top_k: 5)
      expect(r.vectors.first.distance).to eq(0.05)
    end

    it "#delete raises VectorBucketException when the batch is empty" do
      expect { idx.delete([]) }
        .to raise_error(Supabase::Storage::Errors::VectorBucketException, /batch size/)
    end

    it "#delete raises VectorBucketException when the batch exceeds 500" do
      expect { idx.delete(Array.new(501, "k")) }
        .to raise_error(Supabase::Storage::Errors::VectorBucketException, /batch size/)
    end

    it "#delete posts DeleteVectors for a valid batch" do
      stub_request(:post, "#{base}/vector/DeleteVectors").to_return(status: 200, body: "")
      idx.delete(%w[a b c])
    end
  end
end
