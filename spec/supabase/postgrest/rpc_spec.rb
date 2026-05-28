# frozen_string_literal: true

require "supabase/postgrest"

RSpec.describe Supabase::Postgrest::RPCFilterRequestBuilder do
  let(:client) { Supabase::Postgrest::Client.new(base_url: "https://example.com/rest/v1") }

  describe "chaining filters onto rpc()" do
    it "supports eq/order/limit on top of the POST body" do
      rpc = client.rpc("get_active", { tenant: "x" })
                  .eq("status", "active")
                  .order("created_at", desc: true)
                  .limit(5)

      expect(rpc.request.http_method).to eq("POST")
      expect(rpc.request.json).to eq(tenant: "x")
      expect(rpc.request.params).to include(
        "status" => "eq.active",
        "order"  => "created_at.desc",
        "limit"  => 5
      )
    end
  end

  describe "#single / #maybe_single / #csv on an RPC call" do
    it "single() sets the vnd.pgrst.object Accept header and stays chainable" do
      rpc = client.rpc("fn").single
      expect(rpc.request.headers["Accept"]).to eq("application/vnd.pgrst.object+json")
      expect(rpc).to be_a(described_class)
    end

    it "csv() sets the text/csv Accept header" do
      rpc = client.rpc("fn").csv
      expect(rpc.request.headers["Accept"]).to eq("text/csv")
    end

    it "maybe_single() also sets vnd.pgrst.object (PostgREST returns 200/null vs 406)" do
      rpc = client.rpc("fn").maybe_single
      expect(rpc.request.headers["Accept"]).to eq("application/vnd.pgrst.object+json")
    end
  end

  describe "#select on an RPC" do
    it "appends to the existing select param and forces Prefer=return=representation" do
      rpc = client.rpc("fn").select("a", "b").select("c")
      expect(rpc.request.params["select"]).to eq("a,b,c")
      expect(rpc.request.headers["Prefer"]).to include("return=representation")
    end
  end
end
