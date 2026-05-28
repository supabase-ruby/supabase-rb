# frozen_string_literal: true

require "supabase/postgrest"

RSpec.describe Supabase::Postgrest::RequestBuilder do
  let(:builder) { described_class.new(nil, "/rest/v1/example_table", {}) }

  describe "#select" do
    it "starts a GET request with select=col1,col2 and no Prefer header" do
      b = builder.select("col1", "col2")

      expect(b.request.http_method).to eq("GET")
      expect(b.request.params["select"]).to eq("col1,col2")
      expect(b.request.headers["Prefer"]).to be_nil
      expect(b.request.json).to be_nil
    end

    it "selects all columns by default" do
      expect(builder.select.request.params["select"]).to eq("*")
    end

    it "switches to HEAD when head: true (no body fetched, useful for count-only)" do
      b = builder.select("*", head: true, count: "exact")
      expect(b.request.http_method).to eq("HEAD")
      expect(b.request.headers["Prefer"]).to eq("count=exact")
    end

    it "returns a SelectRequestBuilder so .order/.limit/.range etc. chain on it" do
      expect(builder.select("*")).to be_a(Supabase::Postgrest::SelectRequestBuilder)
    end

    it "trims whitespace from each column unless it sits inside quotes" do
      b = builder.select("first name", %(table("a, b"))) # second arg keeps the comma inside quotes
      # `first name` -> `firstname`; the quoted segment is preserved verbatim
      expect(b.request.params["select"]).to include("firstname")
      expect(b.request.params["select"]).to include(%("a, b"))
    end
  end

  describe "#insert" do
    it "defaults to POST with Prefer=return=representation and the row as the JSON body" do
      b = builder.insert({ "key1" => "val1" })

      expect(b.request.http_method).to eq("POST")
      expect(b.request.headers["Prefer"]).to eq("return=representation")
      expect(b.request.json).to eq("key1" => "val1")
    end

    it "appends count=<mode> onto the Prefer header" do
      b = builder.insert({ "k" => "v" }, count: "exact")
      expect(b.request.headers["Prefer"]).to eq("return=representation,count=exact")
    end

    it "adds resolution=merge-duplicates when upsert: true" do
      b = builder.insert({ "k" => "v" }, upsert: true)
      expect(b.request.headers["Prefer"])
        .to eq("return=representation,resolution=merge-duplicates")
    end

    it "adds missing=default when default_to_null: false" do
      b = builder.insert({ "k" => "v" }, default_to_null: false)
      expect(b.request.headers["Prefer"]).to include("missing=default")
    end

    it "passes columns= as a quoted, comma-joined list for bulk inserts" do
      b = builder.insert([{ "k1" => "v1", "k2" => "v2" }, { "k3" => "v3" }])
      cols = b.request.params["columns"].split(",")
      expect(cols).to contain_exactly(%("k1"), %("k2"), %("k3"))
    end

    it "lets you chain .select() to upgrade returning=minimal back to representation" do
      b = builder.insert({ "k" => "v" },
                         returning: Supabase::Postgrest::Types::ReturnMethod::MINIMAL).select("id")

      expect(b.request.params["select"]).to eq("id")
      expect(b.request.headers["Prefer"]).to eq("return=representation")
    end
  end

  describe "#upsert" do
    it "writes resolution=merge-duplicates by default" do
      b = builder.upsert({ "k" => "v" })
      expect(b.request.headers["Prefer"])
        .to eq("return=representation,resolution=merge-duplicates")
    end

    it "switches to resolution=ignore-duplicates when ignore_duplicates: true" do
      b = builder.upsert({ "k" => "v" }, ignore_duplicates: true)
      expect(b.request.headers["Prefer"])
        .to eq("return=representation,resolution=ignore-duplicates")
    end

    it "passes on_conflict through as a query param" do
      b = builder.upsert({ "k" => "v" }, on_conflict: "email")
      expect(b.request.params["on_conflict"]).to eq("email")
    end
  end

  describe "#update" do
    it "uses PATCH and returns a FilterRequestBuilder so you can .eq().select() afterwards" do
      b = builder.update({ "k" => "v" }).eq("id", 1).select("id")

      expect(b.request.http_method).to eq("PATCH")
      expect(b.request.params["id"]).to eq("eq.1")
      expect(b.request.params["select"]).to eq("id")
    end
  end

  describe "#delete" do
    it "uses DELETE with an empty body and supports filter+select chaining" do
      b = builder.delete.eq("id", 1).select("id")

      expect(b.request.http_method).to eq("DELETE")
      expect(b.request.json).to eq({})
      expect(b.request.params["id"]).to eq("eq.1")
      expect(b.request.params["select"]).to eq("id")
    end

    it "respects max_affected by setting handling=strict on the Prefer header" do
      b = builder.delete.max_affected(10)
      expect(b.request.headers["Prefer"]).to include("handling=strict", "max-affected=10")
    end
  end
end
