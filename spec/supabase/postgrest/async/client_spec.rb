# frozen_string_literal: true

require "supabase/postgrest/async"
require "async"
require "webmock/rspec"
require "json"

RSpec.describe Supabase::Postgrest::Async::Client do
  let(:base) { "https://example.supabase.co/rest/v1" }
  let(:users_url) { %r{\Ahttps://example\.supabase\.co/rest/v1/users(\?.*)?\z} }

  let(:client) do
    described_class.new(
      base_url: base,
      headers:  { "apikey" => "anon", "Authorization" => "Bearer tok" }
    )
  end

  describe "type tree" do
    it "is a subclass of the sync Client (so the full public surface is inherited)" do
      expect(described_class.ancestors).to include(Supabase::Postgrest::Client)
    end
  end

  describe "Faraday adapter wiring" do
    it "builds a session that uses the async_http adapter (not the default sync one)" do
      conn = client.send(:build_session)
      expect(conn.builder.adapter.klass.name).to eq("Async::HTTP::Faraday::Adapter")
    end
  end

  describe "#schema" do
    it "returns another Async::Client (not a sync one) so the chain stays async" do
      switched = client.schema("private")
      expect(switched).to be_a(described_class)
      expect(switched.schema_name).to eq("private")
    end
  end

  describe "single call inside Async do" do
    before { WebMock.disable_net_connect! }
    after  { WebMock.allow_net_connect! }

    it "executes a select and returns an APIResponse" do
      stub_request(:get, users_url)
        .to_return(status: 200, body: JSON.generate([{ "id" => 1, "name" => "Ada" }]),
                   headers: { "Content-Type" => "application/json" })

      resp = nil
      Async do
        resp = client.from("users").select("id,name").execute
      end.wait

      expect(resp).to be_a(Supabase::Postgrest::APIResponse)
      expect(resp.data).to eq([{ "id" => 1, "name" => "Ada" }])
    end

    it "raises APIError through the fiber boundary on a 4xx response" do
      stub_request(:get, users_url).to_return(
        status: 400,
        body:   JSON.generate("message" => "bad", "code" => "PGRST100")
      )

      Async do
        expect { client.from("users").select("*").execute }
          .to raise_error(Supabase::Postgrest::Errors::APIError)
      end.wait
    end
  end

  describe "concurrent calls in one Async do |task|" do
    before { WebMock.disable_net_connect! }
    after  { WebMock.allow_net_connect! }

    # Don't measure wall time here — that lives in spike_spec.rb against real
    # infra. Here we only verify N tasks running in one block all complete and
    # return distinct data.
    it "fans out N parallel selects and collects N independent results" do
      n = 5
      counter = 0
      stub_request(:get, users_url).to_return do
        counter += 1
        { status: 200, body: JSON.generate([{ "id" => counter }]) }
      end

      responses = []
      Async do |task|
        tasks = Array.new(n) do
          task.async { client.from("users").select("*").execute }
        end
        responses = tasks.map(&:wait)
      end.wait

      expect(responses.length).to eq(n)
      expect(responses.map { |r| r.data.first["id"] }).to contain_exactly(*(1..n).to_a)
    end
  end

  describe "POST round trip via async" do
    before { WebMock.disable_net_connect! }
    after  { WebMock.allow_net_connect! }

    it "PATCHes with filter+select chained, same surface as sync" do
      stub_request(:patch, users_url)
        .with(body: JSON.generate("name" => "Ada"))
        .to_return(status: 200, body: JSON.generate([{ "id" => 1, "name" => "Ada" }]))

      resp = nil
      Async do
        resp = client.from("users")
                     .update({ "name" => "Ada" })
                     .eq("id", 1)
                     .select("id,name")
                     .execute
      end.wait

      expect(resp.data.first["name"]).to eq("Ada")
    end
  end
end
