# frozen_string_literal: true

require "supabase/storage"
require "webmock/rspec"
require "json"

RSpec.describe Supabase::Storage::BucketApi do
  let(:base) { "https://x.supabase.co/storage/v1" }
  let(:client) do
    Supabase::Storage::Client.new(
      base_url: base,
      headers:  { "apikey" => "anon", "Authorization" => "Bearer tok" }
    )
  end

  before { WebMock.disable_net_connect! }
  after  { WebMock.allow_net_connect! }

  describe "#list_buckets" do
    it "GETs /bucket and maps the response into Bucket structs" do
      stub_request(:get, "#{base}/bucket")
        .with(headers: { "Authorization" => "Bearer tok" })
        .to_return(
          status:  200,
          body:    JSON.generate([
            { "id" => "avatars", "name" => "avatars", "owner" => "u1", "public" => true,
              "file_size_limit" => nil, "allowed_mime_types" => nil,
              "created_at" => "t1", "updated_at" => "t1" }
          ]),
          headers: { "Content-Type" => "application/json" }
        )

      buckets = client.list_buckets
      expect(buckets.length).to eq(1)
      expect(buckets.first).to be_a(Supabase::Storage::Types::Bucket)
      expect(buckets.first.id).to eq("avatars")
      expect(buckets.first.public).to be true
    end
  end

  describe "#get_bucket" do
    it "GETs /bucket/<id> and returns a single Bucket struct" do
      stub_request(:get, "#{base}/bucket/avatars")
        .to_return(status: 200, body: JSON.generate("id" => "avatars", "name" => "avatars", "public" => false))

      b = client.get_bucket("avatars")
      expect(b.id).to eq("avatars")
      expect(b.public).to be false
    end

    it "raises StorageApiError with the parsed payload on a 4xx" do
      stub_request(:get, "#{base}/bucket/missing").to_return(
        status: 404,
        body:   JSON.generate("message" => "Bucket not found",
                              "error" => "NotFound", "statusCode" => 404)
      )

      expect { client.get_bucket("missing") }
        .to raise_error(Supabase::Storage::Errors::StorageApiError) { |err|
          expect(err.message).to eq("Bucket not found")
          expect(err.code).to eq("NotFound")
          expect(err.status).to eq(404)
        }
    end
  end

  describe "#create_bucket" do
    it "POSTs id+name+public+limits+allowed mime types as the JSON body" do
      stub_request(:post, "#{base}/bucket")
        .with(body: JSON.generate(
          "id" => "avatars", "name" => "avatars",
          "public" => true, "file_size_limit" => 1024,
          "allowed_mime_types" => ["image/png"]
        ))
        .to_return(status: 200, body: JSON.generate("name" => "avatars"))

      result = client.create_bucket("avatars", public: true,
                                              file_size_limit: 1024,
                                              allowed_mime_types: ["image/png"])
      expect(result).to eq("name" => "avatars")
    end

    it "omits optional fields when the caller doesn't pass them (avoids overwriting server defaults)" do
      stub_request(:post, "#{base}/bucket")
        .with(body: JSON.generate("id" => "x", "name" => "x"))
        .to_return(status: 200, body: "{}")

      client.create_bucket("x")
    end

    it "defaults the bucket display name to the id when name: is omitted" do
      stub_request(:post, "#{base}/bucket")
        .with(body: JSON.generate("id" => "x", "name" => "x"))
        .to_return(status: 200, body: "{}")

      client.create_bucket("x")
    end
  end

  describe "#update_bucket" do
    it "PUTs id+name+given options" do
      stub_request(:put, "#{base}/bucket/avatars")
        .with(body: JSON.generate("id" => "avatars", "name" => "avatars", "public" => false))
        .to_return(status: 200, body: "{}")

      client.update_bucket("avatars", public: false)
    end
  end

  describe "#empty_bucket" do
    it "POSTs an empty JSON body to /bucket/<id>/empty" do
      stub_request(:post, "#{base}/bucket/avatars/empty")
        .with(body: "{}")
        .to_return(status: 200, body: JSON.generate("message" => "Successfully emptied"))

      expect(client.empty_bucket("avatars")).to eq("message" => "Successfully emptied")
    end
  end

  describe "#delete_bucket" do
    it "DELETEs /bucket/<id> with an empty JSON body" do
      stub_request(:delete, "#{base}/bucket/avatars")
        .with(body: "{}")
        .to_return(status: 200, body: JSON.generate("message" => "Successfully deleted"))

      expect(client.delete_bucket("avatars")).to eq("message" => "Successfully deleted")
    end
  end

  describe "error parsing" do
    it "falls back to a synthetic message when the error body isn't JSON" do
      stub_request(:get, "#{base}/bucket").to_return(status: 502, body: "Bad Gateway")

      expect { client.list_buckets }
        .to raise_error(Supabase::Storage::Errors::StorageApiError) { |err|
          expect(err.message).to eq("HTTP 502")
          expect(err.code).to eq("InternalError")
          expect(err.status).to eq(502)
        }
    end
  end
end
