# frozen_string_literal: true

require "supabase/storage"
require "webmock/rspec"
require "json"
require "stringio"

RSpec.describe Supabase::Storage::FileApi do
  let(:base)   { "https://x.supabase.co/storage/v1" }
  let(:client) { Supabase::Storage::Client.new(base_url: base, headers: { "apikey" => "anon" }) }
  let(:bucket) { client.from("avatars") }

  before { WebMock.disable_net_connect! }
  after  { WebMock.allow_net_connect! }

  # ---------------------------------------------------------------------------
  # Upload / update — multipart body, header semantics
  # ---------------------------------------------------------------------------

  describe "#upload" do
    it "POSTs a multipart body to /object/<bucket>/<path> and returns an UploadResponse" do
      stub_request(:post, "#{base}/object/avatars/folder/avatar.png")
        .with do |req|
          req.body.include?("Content-Disposition: form-data; name=\"file\"") &&
            req.headers["Content-Type"].to_s.start_with?("multipart/form-data")
        end
        .to_return(status: 200, body: JSON.generate("Key" => "avatars/folder/avatar.png"))

      result = bucket.upload("folder/avatar.png", "binary-bytes", content_type: "image/png")
      expect(result).to be_a(Supabase::Storage::Types::UploadResponse)
      expect(result.path).to eq("folder/avatar.png")
      expect(result.key).to eq("avatars/folder/avatar.png")
    end

    it "sends x-upsert: true when upsert: true is passed" do
      stub = stub_request(:post, "#{base}/object/avatars/x.png")
             .with(headers: { "x-upsert" => "true" })
             .to_return(status: 200, body: JSON.generate("Key" => "avatars/x.png"))

      bucket.upload("x.png", "data", upsert: true)
      expect(stub).to have_been_requested
    end

    it "translates cache_control: <n> into both a header and the multipart cacheControl field" do
      stub = stub_request(:post, "#{base}/object/avatars/x.png")
             .with(headers: { "cache-control" => "max-age=3600" })
             .with do |req|
               req.body.include?("cacheControl") && req.body.include?("3600")
             end
             .to_return(status: 200, body: JSON.generate("Key" => "avatars/x.png"))

      bucket.upload("x.png", "data", cache_control: 3600)
      expect(stub).to have_been_requested
    end

    it "base64-encodes metadata: into the x-metadata header" do
      expected = ["#{JSON.generate(user: 'u1')}"].pack("m0")
      stub = stub_request(:post, "#{base}/object/avatars/x.png")
             .with(headers: { "x-metadata" => expected })
             .to_return(status: 200, body: JSON.generate("Key" => "avatars/x.png"))

      bucket.upload("x.png", "data", metadata: { user: "u1" })
      expect(stub).to have_been_requested
    end

    it "accepts an IO-like object as the file body" do
      stub = stub_request(:post, "#{base}/object/avatars/x.png")
             .to_return(status: 200, body: JSON.generate("Key" => "avatars/x.png"))

      io = StringIO.new("hello world")
      result = bucket.upload("x.png", io)
      expect(stub).to have_been_requested
      expect(result.key).to eq("avatars/x.png")
    end

    it "rejects values that aren't bytes, IO, or Pathname" do
      expect { bucket.upload("x.png", 42) }.to raise_error(ArgumentError, /String, IO, or Pathname/)
    end

    it "raises StorageApiError on a 4xx response" do
      stub_request(:post, "#{base}/object/avatars/x.png").to_return(
        status: 400,
        body:   JSON.generate("message" => "Duplicate", "error" => "Conflict", "statusCode" => 400)
      )

      expect { bucket.upload("x.png", "data") }
        .to raise_error(Supabase::Storage::Errors::StorageApiError, /Duplicate/)
    end
  end

  describe "#update" do
    it "PUTs to the same object path and never sends x-upsert (PUT is always upsert)" do
      stub = stub_request(:put, "#{base}/object/avatars/x.png")
             .with { |req| !req.headers.key?("x-upsert") && !req.headers.key?("X-Upsert") }
             .to_return(status: 200, body: JSON.generate("Key" => "avatars/x.png"))

      bucket.update("x.png", "data")
      expect(stub).to have_been_requested
    end
  end

  # ---------------------------------------------------------------------------
  # Download
  # ---------------------------------------------------------------------------

  describe "#download" do
    it "GETs /object/<bucket>/<path> and returns the raw bytes" do
      png_bytes = "\x89PNG\r\n\x1A\n".b
      stub_request(:get, "#{base}/object/avatars/x.png")
        .to_return(status: 200, body: png_bytes, headers: { "Content-Type" => "image/png" })

      expect(bucket.download("x.png")).to eq(png_bytes)
    end
  end

  # ---------------------------------------------------------------------------
  # List
  # ---------------------------------------------------------------------------

  describe "#list" do
    it "POSTs /object/list/<bucket> with DEFAULT_SEARCH_OPTIONS merged onto prefix" do
      stub_request(:post, "#{base}/object/list/avatars")
        .with(body: JSON.generate(
          "limit" => 100, "offset" => 0,
          "sortBy" => { "column" => "name", "order" => "asc" },
          "prefix" => "folder/"
        ))
        .to_return(status: 200, body: JSON.generate([{ "name" => "x.png" }]))

      result = bucket.list("folder/")
      expect(result).to eq([{ "name" => "x.png" }])
    end

    it "lets the caller override limit/offset/sort_by/search" do
      stub_request(:post, "#{base}/object/list/avatars")
        .with(body: JSON.generate(
          "limit"  => 10, "offset" => 5,
          "sortBy" => { "column" => "updated_at", "order" => "desc" },
          "search" => "ada",
          "prefix" => ""
        ))
        .to_return(status: 200, body: "[]")

      bucket.list(nil, limit: 10, offset: 5,
                  sort_by: { column: "updated_at", order: "desc" }, search: "ada")
    end
  end

  describe "#list_v2" do
    it "POSTs /object/list-v2/<bucket> with only the keys the caller passed and returns a SearchV2Result" do
      stub_request(:post, "#{base}/object/list-v2/avatars")
        .with(body: JSON.generate(
          "prefix"         => "folder/",
          "limit"          => 50,
          "cursor"         => "abc123",
          "with_delimiter" => true,
          "sortBy"         => { "column" => "created_at", "order" => "desc" }
        ))
        .to_return(status: 200, body: JSON.generate(
          "hasNext"    => true,
          "nextCursor" => "next-token",
          "folders"    => [{ "key" => "folder/sub/", "name" => "sub" }],
          "objects"    => [{ "id" => "1", "name" => "a.png", "key" => "folder/a.png",
                             "metadata" => { "size" => 10 } }]
        ))

      result = bucket.list_v2(
        prefix: "folder/", limit: 50, cursor: "abc123", with_delimiter: true,
        sort_by: { column: "created_at", order: "desc" }
      )

      expect(result).to be_a(Supabase::Storage::Types::SearchV2Result)
      expect(result.has_next).to be(true)
      expect(result.hasNext).to be(true)
      expect(result.next_cursor).to eq("next-token")
      expect(result.folders.first.key).to eq("folder/sub/")
      expect(result.objects.first.name).to eq("a.png")
      expect(result.objects.first.metadata).to eq("size" => 10)
    end

    it "sends an empty body when no options are passed" do
      stub_request(:post, "#{base}/object/list-v2/avatars")
        .with(body: "{}")
        .to_return(status: 200, body: JSON.generate("hasNext" => false, "folders" => [], "objects" => []))

      result = bucket.list_v2
      expect(result.has_next).to be(false)
      expect(result.folders).to eq([])
      expect(result.objects).to eq([])
    end
  end

  # ---------------------------------------------------------------------------
  # Remove / Move / Copy / Info / Exists
  # ---------------------------------------------------------------------------

  describe "#remove" do
    it "DELETEs /object/<bucket> with the paths under the `prefixes` key" do
      stub_request(:delete, "#{base}/object/avatars")
        .with(body: JSON.generate("prefixes" => %w[a.png b.png]))
        .to_return(status: 200, body: "[]")

      bucket.remove(%w[a.png b.png])
    end

    it "wraps a single path in an array for the caller" do
      stub = stub_request(:delete, "#{base}/object/avatars")
             .with(body: JSON.generate("prefixes" => ["a.png"]))
             .to_return(status: 200, body: "[]")

      bucket.remove("a.png")
      expect(stub).to have_been_requested
    end
  end

  describe "#move" do
    it "POSTs source/destination + bucket id to /object/move" do
      stub_request(:post, "#{base}/object/move")
        .with(body: JSON.generate(
          "bucketId" => "avatars", "sourceKey" => "a.png", "destinationKey" => "b.png"
        ))
        .to_return(status: 200, body: JSON.generate("message" => "Successfully moved"))

      expect(bucket.move("a.png", "b.png")).to eq("message" => "Successfully moved")
    end
  end

  describe "#copy" do
    it "POSTs to /object/copy" do
      stub_request(:post, "#{base}/object/copy")
        .with(body: JSON.generate(
          "bucketId" => "avatars", "sourceKey" => "a.png", "destinationKey" => "b.png"
        ))
        .to_return(status: 200, body: JSON.generate("Key" => "avatars/b.png"))

      bucket.copy("a.png", "b.png")
    end
  end

  describe "#info" do
    it "GETs /object/info/<bucket>/<path>" do
      stub_request(:get, "#{base}/object/info/avatars/x.png")
        .to_return(status: 200, body: JSON.generate("size" => 100, "name" => "x.png"))

      expect(bucket.info("x.png")).to eq("size" => 100, "name" => "x.png")
    end
  end

  describe "#exists?" do
    it "is true when HEAD returns 200" do
      stub_request(:head, "#{base}/object/avatars/x.png").to_return(status: 200)
      expect(bucket.exists?("x.png")).to be true
    end

    it "is false when the API responds with an error" do
      stub_request(:head, "#{base}/object/avatars/missing.png")
        .to_return(status: 404, body: JSON.generate("message" => "Not found",
                                                    "error" => "NotFound", "statusCode" => 404))
      expect(bucket.exists?("missing.png")).to be false
    end
  end

  # ---------------------------------------------------------------------------
  # Signed URLs
  # ---------------------------------------------------------------------------

  describe "#create_signed_url" do
    it "POSTs expiresIn and returns the full signed URL anchored under the base" do
      stub_request(:post, "#{base}/object/sign/avatars/x.png")
        .with(body: JSON.generate("expiresIn" => "3600"))
        .to_return(status: 200, body: JSON.generate("signedURL" => "/object/sign/avatars/x.png?token=tok"))

      result = bucket.create_signed_url("x.png", expires_in: 3600)
      expect(result["signedURL"]).to eq("#{base}/object/sign/avatars/x.png?token=tok")
      expect(result["signedUrl"]).to eq(result["signedURL"])
    end

    it "appends a download query param when download: true" do
      stub_request(:post, "#{base}/object/sign/avatars/x.png")
        .with(body: JSON.generate("expiresIn" => "3600", "download" => true))
        .to_return(status: 200, body: JSON.generate("signedURL" => "/object/sign/avatars/x.png?token=tok"))

      result = bucket.create_signed_url("x.png", expires_in: 3600, download: true)
      expect(result["signedURL"]).to include("token=tok")
      expect(result["signedURL"]).to include("download=")
    end

    it "returns nil URLs when the API gives no signedURL back" do
      stub_request(:post, "#{base}/object/sign/avatars/x.png")
        .to_return(status: 200, body: JSON.generate({}))

      result = bucket.create_signed_url("x.png", expires_in: 60)
      expect(result["signedURL"]).to be_nil
      expect(result["signedUrl"]).to be_nil
    end
  end

  describe "#create_signed_urls" do
    it "POSTs the path list + expiresIn and decorates each item with the full URL" do
      stub_request(:post, "#{base}/object/sign/avatars")
        .with(body: JSON.generate("paths" => %w[a.png b.png], "expiresIn" => "60"))
        .to_return(status: 200, body: JSON.generate([
          { "error" => nil, "path" => "a.png", "signedURL" => "/object/sign/avatars/a.png?token=ta" },
          { "error" => nil, "path" => "b.png", "signedURL" => "/object/sign/avatars/b.png?token=tb" }
        ]))

      result = bucket.create_signed_urls(%w[a.png b.png], expires_in: 60)
      expect(result.length).to eq(2)
      expect(result[0]["signedURL"]).to eq("#{base}/object/sign/avatars/a.png?token=ta")
      expect(result[1]["signedURL"]).to eq("#{base}/object/sign/avatars/b.png?token=tb")
    end
  end

  describe "#get_public_url" do
    it "builds a /object/public/<bucket>/<path> URL with no HTTP call" do
      url = bucket.get_public_url("folder/x.png")
      expect(url).to eq("#{base}/object/public/avatars/folder/x.png")
    end

    it "uses /render/image/public when transform: is provided" do
      url = bucket.get_public_url("x.png", transform: { width: 100, height: 200 })
      expect(url).to start_with("#{base}/render/image/public/avatars/x.png?")
      expect(url).to include("width=100")
      expect(url).to include("height=200")
    end

    it "appends download= as a query param" do
      url = bucket.get_public_url("x.png", download: "renamed.png")
      expect(url).to include("download=renamed.png")
    end
  end

  describe "#create_signed_upload_url" do
    it "POSTs to /object/upload/sign/... and extracts the token from the returned URL" do
      stub_request(:post, "#{base}/object/upload/sign/avatars/x.png")
        .to_return(status: 200, body: JSON.generate("url" => "/object/upload/sign/avatars/x.png?token=abc"))

      result = bucket.create_signed_upload_url("x.png")
      expect(result).to be_a(Supabase::Storage::Types::SignedUploadURL)
      expect(result.token).to eq("abc")
      expect(result.signed_url).to eq("#{base}/object/upload/sign/avatars/x.png?token=abc")
      expect(result.path).to eq("x.png")
    end

    it "raises if the API returns a URL without a token" do
      stub_request(:post, "#{base}/object/upload/sign/avatars/x.png")
        .to_return(status: 200, body: JSON.generate("url" => "/object/upload/sign/avatars/x.png"))

      expect { bucket.create_signed_upload_url("x.png") }
        .to raise_error(Supabase::Storage::Errors::StorageError, /No token/)
    end

    it "sends x-upsert: <bool> when upsert: is given" do
      stub = stub_request(:post, "#{base}/object/upload/sign/avatars/x.png")
             .with(headers: { "x-upsert" => "true" })
             .to_return(status: 200, body: JSON.generate("url" => "/object/upload/sign/avatars/x.png?token=t"))

      bucket.create_signed_upload_url("x.png", upsert: true)
      expect(stub).to have_been_requested
    end
  end

  describe "#upload_to_signed_url" do
    it "PUTs a multipart body to the signed upload endpoint with the token in the query string" do
      stub = stub_request(:put, "#{base}/object/upload/sign/avatars/x.png?token=tok")
             .with do |req|
               req.body.include?("Content-Disposition: form-data; name=\"file\"")
             end
             .to_return(status: 200, body: JSON.generate("Key" => "avatars/x.png"))

      result = bucket.upload_to_signed_url("x.png", token: "tok", file: "data")
      expect(stub).to have_been_requested
      expect(result.key).to eq("avatars/x.png")
    end
  end
end
