# frozen_string_literal: true

require "supabase/postgrest"

RSpec.describe Supabase::Postgrest::SelectRequestBuilder do
  let(:builder) { Supabase::Postgrest::RequestBuilder.new(nil, "/rest/v1/example_table", {}).select("*") }

  describe "#order" do
    it "encodes a single order as `column.asc` (or `.desc` when desc: true)" do
      builder.order("name", desc: true)
      expect(builder.request.params["order"]).to eq("name.desc")
    end

    it "comma-joins multiple .order() calls into a single query param" do
      builder.order("name", desc: true).order("iso", desc: true)
      expect(builder.request.params["order"]).to eq("name.desc,iso.desc")
    end

    it "namespaces order under the foreign table when foreign_table: is supplied" do
      builder.order("city_name", desc: true, foreign_table: "cities")
      expect(builder.request.params["cities.order"]).to eq("city_name.desc")
    end

    it "appends nullsfirst / nullslast when nullsfirst: is set" do
      builder.order("name", nullsfirst: true)
      expect(builder.request.params["order"]).to eq("name.asc.nullsfirst")

      b2 = Supabase::Postgrest::RequestBuilder.new(nil, "/t", {}).select("*")
      b2.order("name", nullsfirst: false)
      expect(b2.request.params["order"]).to eq("name.asc.nullslast")
    end
  end

  describe "#limit / #offset" do
    it "writes limit and offset query params for the main table" do
      builder.limit(10).offset(20)
      expect(builder.request.params).to include("limit" => 10, "offset" => 20)
    end

    it "namespaces limit under the foreign table when foreign_table: is supplied" do
      builder.limit(5, foreign_table: "cities")
      expect(builder.request.params["cities.limit"]).to eq(5)
    end
  end

  describe "#range" do
    it "translates (start, finish) into offset=start, limit=(finish-start+1)" do
      builder.range(0, 1)
      expect(builder.request.params).to include("offset" => 0, "limit" => 2)
    end

    it "namespaces both offset and limit under the foreign table when supplied" do
      builder.range(1, 2, foreign_table: "cities")
      expect(builder.request.params).to include(
        "cities.offset" => 1, "cities.limit" => 2
      )
    end
  end

  describe "#single" do
    it "asks for vnd.pgrst.object+json and returns a SingleRequestBuilder" do
      single = builder.single
      expect(builder.request.headers["Accept"]).to eq("application/vnd.pgrst.object+json")
      expect(single).to be_a(Supabase::Postgrest::SingleRequestBuilder)
    end
  end

  describe "#maybe_single" do
    it "leaves the Accept header alone and returns a MaybeSingleRequestBuilder" do
      ms = builder.maybe_single
      expect(builder.request.headers["Accept"]).to be_nil
      expect(ms).to be_a(Supabase::Postgrest::MaybeSingleRequestBuilder)
    end
  end

  describe "#csv" do
    it "asks for text/csv and returns a SingleRequestBuilder" do
      csv = builder.csv
      expect(builder.request.headers["Accept"]).to eq("text/csv")
      expect(csv).to be_a(Supabase::Postgrest::SingleRequestBuilder)
    end
  end

  describe "#text_search" do
    it "writes <type>fts(<config>).<query> into the column query param" do
      builder.text_search("catchphrase", "'fat' & 'cat'", type: "plain", config: "english")
      expect(builder.request.params["catchphrase"]).to eq("plfts(english).'fat' & 'cat'")
    end

    it "supports phrase and web_search types and omits config when not provided" do
      builder.text_search("col", "q", type: "phrase")
      expect(builder.request.params["col"]).to eq("phfts.q")

      b2 = Supabase::Postgrest::RequestBuilder.new(nil, "/t", {}).select("*")
      b2.text_search("col", "q", type: "web_search")
      expect(b2.request.params["col"]).to eq("wfts.q")
    end

    it "falls back to the bare `fts` operator when no type is given" do
      builder.text_search("col", "q")
      expect(builder.request.params["col"]).to eq("fts.q")
    end
  end

  describe "#explain" do
    it "defaults to text format with no options and returns an ExplainRequestBuilder" do
      e = builder.explain
      expect(builder.request.headers["Accept"]).to eq("application/vnd.pgrst.plan+text; options=")
      expect(e).to be_a(Supabase::Postgrest::ExplainRequestBuilder)
    end

    it "joins enabled options with `|` and uses SingleRequestBuilder when format is JSON" do
      e = builder.explain(format: "json", analyze: true, verbose: true, buffers: true, wal: true)
      expect(builder.request.headers["Accept"])
        .to eq("application/vnd.pgrst.plan+json; options=analyze|verbose|buffers|wal")
      expect(e).to be_a(Supabase::Postgrest::SingleRequestBuilder)
    end

    it "includes settings when settings: true" do
      builder.explain(settings: true)
      expect(builder.request.headers["Accept"]).to include("options=settings")
    end
  end
end
