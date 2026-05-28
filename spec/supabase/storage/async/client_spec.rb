# frozen_string_literal: true

require "supabase/storage/async"
require "async"
require "webmock/rspec"
require "json"
require "stringio"

RSpec.describe Supabase::Storage::Async::Client do
  let(:base) { "https://x.supabase.co/storage/v1" }
  let(:client) do
    described_class.new(base_url: base, headers: { "apikey" => "anon" })
  end

  describe "type tree" do
    it "is a subclass of the sync Client (so the full public surface is inherited)" do
      expect(described_class.ancestors).to include(Supabase::Storage::Client)
    end
  end

  describe "Faraday adapter wiring" do
    it "uses the async_http adapter (not the default sync one)" do
      conn = client.instance_variable_get(:@session)
      expect(conn.builder.adapter.klass.name).to eq("Async::HTTP::Faraday::Adapter")
    end

    it "still installs the multipart request middleware so uploads encode correctly" do
      conn = client.instance_variable_get(:@session)
      handler_names = conn.builder.handlers.map { |h| h.klass.name }
      expect(handler_names).to include(a_string_matching(/Multipart/))
    end
  end

  describe "single call inside Async do" do
    before { WebMock.disable_net_connect! }
    after  { WebMock.allow_net_connect! }

    it "executes list_buckets and parses the response into Bucket structs" do
      stub_request(:get, "#{base}/bucket").to_return(
        status:  200,
        body:    JSON.generate([{ "id" => "avatars", "name" => "avatars", "public" => true }]),
        headers: { "Content-Type" => "application/json" }
      )

      buckets = nil
      Async do
        buckets = client.list_buckets
      end.wait

      expect(buckets.length).to eq(1)
      expect(buckets.first.id).to eq("avatars")
    end

    it "raises StorageApiError through the fiber boundary on a 4xx response" do
      stub_request(:get, "#{base}/bucket/missing").to_return(
        status: 404,
        body:   JSON.generate("message" => "Not found", "error" => "NotFound", "statusCode" => 404)
      )

      Async do
        expect { client.get_bucket("missing") }
          .to raise_error(Supabase::Storage::Errors::StorageApiError, /Not found/)
      end.wait
    end
  end

  describe "concurrent calls in one Async do |task|" do
    before { WebMock.disable_net_connect! }
    after  { WebMock.allow_net_connect! }

    # Don't measure wall time here — the auth spike already validated the async-
    # http-faraday stack. Here we only verify N tasks dispatched in one block
    # all complete and return distinct data.
    it "fans out N parallel get_bucket calls and collects N independent results" do
      n = 5
      n.times do |i|
        stub_request(:get, "#{base}/bucket/b#{i}").to_return(
          status: 200, body: JSON.generate("id" => "b#{i}", "name" => "b#{i}", "public" => false)
        )
      end

      results = []
      Async do |task|
        tasks = (0...n).map do |i|
          task.async { client.get_bucket("b#{i}") }
        end
        results = tasks.map(&:wait)
      end.wait

      expect(results.length).to eq(n)
      expect(results.map(&:id)).to contain_exactly("b0", "b1", "b2", "b3", "b4")
    end
  end

  describe "FileApi access via async client" do
    before { WebMock.disable_net_connect! }
    after  { WebMock.allow_net_connect! }

    it "delegates uploads through the async session (multipart still works)" do
      stub = stub_request(:post, "#{base}/object/avatars/x.png")
             .with do |req|
               req.body.include?("Content-Disposition: form-data; name=\"file\"") &&
                 req.headers["Content-Type"].to_s.start_with?("multipart/form-data")
             end
             .to_return(status: 200, body: JSON.generate("Key" => "avatars/x.png"))

      result = nil
      Async do
        result = client.from("avatars").upload("x.png", "bytes", content_type: "image/png")
      end.wait

      expect(stub).to have_been_requested
      expect(result.key).to eq("avatars/x.png")
    end

    it "downloads through the async session and returns raw bytes" do
      png = "\x89PNG\r\n\x1A\n".b
      stub_request(:get, "#{base}/object/avatars/x.png").to_return(status: 200, body: png)

      bytes = nil
      Async do
        bytes = client.from("avatars").download("x.png")
      end.wait

      expect(bytes).to eq(png)
    end
  end
end
