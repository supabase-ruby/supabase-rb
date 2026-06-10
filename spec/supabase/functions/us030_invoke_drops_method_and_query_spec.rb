# frozen_string_literal: true

require "supabase/functions"
require "webmock/rspec"
require "json"

# US-030 — Functions invoke drops the JS-only `method:` and `query:` kwargs.
#
# AC: kwargs `method:` and `query:` removed from `#invoke` (parity with
# supabase-py; the JS surface was the only reason they ever existed). Ruby's
# normal kwargs validation now raises `ArgumentError` on any call site that
# passes them — no custom validation needed, no silent ignore.
RSpec.describe "Supabase::Functions::Client#invoke — US-030" do
  let(:base) { "https://x.supabase.co/functions/v1" }
  let(:client) do
    Supabase::Functions::Client.new(
      base_url: base,
      headers:  { "Authorization" => "Bearer tok" }
    )
  end

  before { WebMock.disable_net_connect! }
  after  { WebMock.allow_net_connect! }

  describe "method: kwarg removed (AC #1 + AC #3)" do
    it "raises ArgumentError for invoke(name, method: 'GET')" do
      expect { client.invoke("fn", method: "GET") }
        .to raise_error(ArgumentError, /method/)
    end

    it "raises ArgumentError for invoke(name, method: 'POST') even when the value would match the default" do
      # Pins the contract: removal is unconditional, not "only when the value
      # would differ". If someone tries to be clever and pass method: "POST"
      # explicitly to document intent, it still has to fail — otherwise the
      # JS-ism leaks back via the principle of least surprise.
      expect { client.invoke("fn", method: "POST") }
        .to raise_error(ArgumentError, /method/)
    end
  end

  describe "query: kwarg removed (AC #1)" do
    it "raises ArgumentError for invoke(name, query: {...})" do
      expect { client.invoke("fn", query: { a: 1 }) }
        .to raise_error(ArgumentError, /query/)
    end
  end

  describe "invoke without method:/query: still works (positive guard)" do
    it "POSTs without a query string when called with only the supported kwargs" do
      stub = stub_request(:post, "#{base}/fn")
             .with(body: JSON.generate("k" => "v"),
                   headers: { "Content-Type" => "application/json" })
             .to_return(status: 200, body: "")
      client.invoke("fn", body: { k: "v" })
      expect(stub).to have_been_requested
    end

    it "still threads region routing through forceFunctionRegion (only path that emits a query string)" do
      # Removing the public `query:` kwarg must not break the internal use of
      # query params for region routing — that's the single remaining query
      # contributor.
      stub = stub_request(:post, "#{base}/fn")
             .with(query:   { "forceFunctionRegion" => "us-east-1" },
                   headers: { "x-region" => "us-east-1" })
             .to_return(status: 200, body: "")
      client.invoke("fn", region: "us-east-1")
      expect(stub).to have_been_requested
    end
  end

  describe "kwarg surface pinned (regression guard)" do
    it "exposes exactly the supabase-py-aligned kwargs on #invoke" do
      # Frozen list — if someone re-adds method:/query: (or any other JS-ism),
      # this assertion will flip and the failing diff will tell the next
      # reviewer exactly which kwarg crept back in.
      params = Supabase::Functions::Client.instance_method(:invoke).parameters
      keyword_names = params.select { |type, _| %i[key keyreq].include?(type) }.map(&:last)
      expect(keyword_names).to contain_exactly(
        :body, :headers, :region, :response_type, :return_response
      )
    end
  end
end
