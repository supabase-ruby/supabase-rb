# frozen_string_literal: true

require "supabase/postgrest"

RSpec.describe "PostgREST query string encoding" do
  let(:client) do
    Supabase::Postgrest::Client.new(
      base_url: "https://example.supabase.co/rest/v1",
      headers:  { "apikey" => "anon" }
    )
  end

  it "wires FlatParamsEncoder into the Faraday session" do
    session = client.send(:session)
    expect(session.options.params_encoder).to eq(Faraday::FlatParamsEncoder)
  end

  it "encodes repeated filters on the same column as `x=gte.a&x=lte.b`" do
    builder = client.from("users").select("*").gte("x", "a").lte("x", "b")
    expect_query(builder, "select=%2A&x=gte.a&x=lte.b")
  end

  it "encodes negated repeats on the same column as separate `x=` params" do
    builder = client.from("users").select("*").eq("x", "1").not_.eq("x", "2")
    expect_query(builder, "select=%2A&x=eq.1&x=not.eq.2")
  end

  it "encodes `or_(...)` as a single `or=(...)` query parameter" do
    builder = client.from("users").select("*").or_("x.eq.1,y.eq.2")
    expect_query(builder, "or=%28x.eq.1%2Cy.eq.2%29&select=%2A")
  end

  it "encodes a single value identically to before (scalar, not array)" do
    builder = client.from("users").select("*").eq("id", "1")
    expect_query(builder, "id=eq.1&select=%2A")
  end

  context "without FlatParamsEncoder (regression guard)" do
    it "would emit `x[]=...` instead of repeated `x=...` params" do
      builder = client.from("users").select("*").gte("x", "a").lte("x", "b")

      request = builder.request
      method = request.http_method.downcase.to_sym
      captured = nil

      bad_session = Faraday.new(url: "https://example.supabase.co/rest/v1") do |f|
        # No params_encoder override — Faraday defaults to NestedParamsEncoder.
        f.adapter :test do |stub|
          stub.send(method, request.path) do |env|
            captured = env.url.query.to_s
            [200, { "Content-Type" => "application/json" }, "[]"]
          end
        end
      end

      request.session = bad_session
      builder.execute

      expect(captured).to include("x%5B%5D=") # `x[]=` — wrong, breaks PostgREST
      expect(captured).not_to eq("select=%2A&x=gte.a&x=lte.b")
    end
  end
end
