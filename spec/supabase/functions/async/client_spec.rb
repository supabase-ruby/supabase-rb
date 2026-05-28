# frozen_string_literal: true

require "supabase/functions/async"
require "async"
require "webmock/rspec"
require "json"

RSpec.describe Supabase::Functions::Async::Client do
  let(:base)   { "https://x.supabase.co/functions/v1" }
  let(:client) do
    described_class.new(base_url: base, headers: { "Authorization" => "Bearer tok" })
  end

  describe "type tree" do
    it "is a subclass of the sync Client (so the full public surface is inherited)" do
      expect(described_class.ancestors).to include(Supabase::Functions::Client)
    end
  end

  describe "Faraday adapter wiring" do
    it "uses the async_http adapter (not the default sync one)" do
      conn = client.instance_variable_get(:@session)
      expect(conn.builder.adapter.klass.name).to eq("Async::HTTP::Faraday::Adapter")
    end
  end

  describe "single invocation inside Async do" do
    before { WebMock.disable_net_connect! }
    after  { WebMock.allow_net_connect! }

    it "POSTs and returns a parsed JSON Response struct" do
      stub_request(:post, "#{base}/hello")
        .with(body: JSON.generate("name" => "Ada"))
        .to_return(status: 200, body: JSON.generate("greeting" => "hi Ada"),
                   headers: { "Content-Type" => "application/json" })

      result = nil
      Async do
        result = client.invoke("hello", body: { name: "Ada" })
      end.wait

      expect(result.status).to eq(200)
      expect(result.data).to eq("greeting" => "hi Ada")
    end

    it "raises FunctionsHttpError through the fiber boundary on a 5xx" do
      stub_request(:post, "#{base}/fn").to_return(
        status: 500, body: JSON.generate("error" => "boom")
      )

      Async do
        expect { client.invoke("fn") }
          .to raise_error(Supabase::Functions::Errors::FunctionsHttpError, /boom/)
      end.wait
    end
  end

  describe "concurrent invocations in one Async do |task|" do
    before { WebMock.disable_net_connect! }
    after  { WebMock.allow_net_connect! }

    it "fans out N parallel invokes and collects N independent Response structs" do
      n = 5
      n.times do |i|
        stub_request(:post, "#{base}/fn#{i}").to_return(
          status: 200, body: JSON.generate("idx" => i),
          headers: { "Content-Type" => "application/json" }
        )
      end

      results = []
      Async do |task|
        tasks = (0...n).map do |i|
          task.async { client.invoke("fn#{i}") }
        end
        results = tasks.map(&:wait)
      end.wait

      expect(results.length).to eq(n)
      expect(results.map { |r| r.data["idx"] }).to contain_exactly(0, 1, 2, 3, 4)
    end
  end
end
