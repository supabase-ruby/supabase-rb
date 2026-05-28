# frozen_string_literal: true

require "supabase/postgrest"

RSpec.describe Supabase::Postgrest::FilterRequestBuilder do
  let(:builder) do
    request = Supabase::Postgrest::RequestConfig.new(
      session: nil, path: "/example_table", http_method: "GET",
      headers: {}, params: {}, json: nil
    )
    described_class.new(request)
  end

  describe "#filter (the underlying primitive)" do
    it "stores `operator.criteria` keyed by the column name" do
      builder.filter("col", "eq", "val")
      expect(builder.request.params).to eq("col" => "eq.val")
    end

    it "quotes column names that contain PostgREST-reserved characters" do
      builder.filter("col:name", "eq", "val")
      expect(builder.request.params).to eq(%("col:name") => "eq.val")
    end

    it "returns self so calls can chain" do
      result = builder.filter("a", "eq", "1")
      expect(result).to be(builder)
    end
  end

  describe "#not_" do
    it "negates the very next operator and only that one" do
      builder.not_.eq("x", "1").eq("y", "2")

      expect(builder.request.params).to include(
        "x" => "not.eq.1",
        "y" => "eq.2"
      )
    end
  end

  describe "comparison operators" do
    it "emits eq/neq/gt/gte/lt/lte with their respective prefixes" do
      builder.eq("a", "1").neq("b", "2").gt("c", "3").gte("d", "4").lt("e", "5").lte("f", "6")

      expect(builder.request.params).to eq(
        "a" => "eq.1",  "b" => "neq.2", "c" => "gt.3",
        "d" => "gte.4", "e" => "lt.5",  "f" => "lte.6"
      )
    end
  end

  describe "#is_" do
    it "encodes IS NULL when the value is nil" do
      builder.is_("flag", nil)
      expect(builder.request.params).to eq("flag" => "is.null")
    end

    it "passes literal truth values through unchanged" do
      builder.is_("flag", "true")
      expect(builder.request.params).to eq("flag" => "is.true")
    end
  end

  describe "LIKE / ILIKE family" do
    it "emits like and ilike unchanged" do
      builder.like("name", "%foo%").ilike("email", "%@gmail.com")

      expect(builder.request.params).to include(
        "name"  => "like.%foo%",
        "email" => "ilike.%@gmail.com"
      )
    end

    it "wraps like_all_of / like_any_of / ilike_all_of / ilike_any_of patterns in braces" do
      builder.like_all_of("a", "A*,*b")
      builder.like_any_of("b", "A*,*b")
      builder.ilike_all_of("c", "A*,*b")
      builder.ilike_any_of("d", "A*,*b")

      expect(builder.request.params).to include(
        "a" => "like(all).{A*,*b}",
        "b" => "like(any).{A*,*b}",
        "c" => "ilike(all).{A*,*b}",
        "d" => "ilike(any).{A*,*b}"
      )
    end
  end

  describe "full-text search operators" do
    it "exposes fts/plfts/phfts/wfts with their PostgREST prefixes" do
      builder.fts("a", "x").plfts("b", "x").phfts("c", "x").wfts("d", "x")

      expect(builder.request.params).to eq(
        "a" => "fts.x", "b" => "plfts.x", "c" => "phfts.x", "d" => "wfts.x"
      )
    end
  end

  describe "#in_" do
    it "joins values inside parentheses" do
      builder.in_("x", %w[a b c])
      expect(builder.request.params).to eq("x" => "in.(a,b,c)")
    end

    it "quotes individual values that contain reserved characters" do
      builder.in_("x", ["a,b", "c"])
      expect(builder.request.params).to eq("x" => %(in.("a,b",c)))
    end
  end

  describe "#contains / #contained_by / #ov (overlaps)" do
    it "passes string values through unchanged" do
      builder.contains("a", "x")
      builder.contained_by("b", "y")
      builder.ov("c", "z")

      expect(builder.request.params).to include(
        "a" => "cs.x", "b" => "cd.y", "c" => "ov.z"
      )
    end

    it "serializes hashes as JSON" do
      builder.contains("a", { k: "v" })
      expect(builder.request.params["a"]).to eq(%(cs.{"k":"v"}))
    end

    it "wraps arrays in PostgREST {a,b,c} array syntax" do
      builder.contains("a", %w[x y])
      builder.contained_by("b", %w[x y])
      builder.ov("c", %w[x y])

      expect(builder.request.params).to include(
        "a" => "cs.{x,y}", "b" => "cd.{x,y}", "c" => "ov.{x,y}"
      )
    end
  end

  describe "range operators" do
    let(:range) { %w[2000-01-02 2000-01-03] }

    it "emits sl/sr/nxl/nxr/adj with parenthesized bounds" do
      builder.sl("a", range)
      builder.sr("b", range)
      builder.nxl("c", range)
      builder.nxr("d", range)
      builder.adj("e", range)

      expect(builder.request.params).to include(
        "a" => "sl.(2000-01-02,2000-01-03)",
        "b" => "sr.(2000-01-02,2000-01-03)",
        "c" => "nxl.(2000-01-02,2000-01-03)",
        "d" => "nxr.(2000-01-02,2000-01-03)",
        "e" => "adj.(2000-01-02,2000-01-03)"
      )
    end

    it "exposes friendly aliases (range_lt/range_gt/range_gte/range_lte/range_adjacent/overlaps)" do
      builder.range_lt("a", range)
      builder.range_gt("b", range)
      builder.range_gte("c", range)
      builder.range_lte("d", range)
      builder.range_adjacent("e", range)
      builder.overlaps("f", %w[x y])

      expect(builder.request.params).to include(
        "a" => "sl.(2000-01-02,2000-01-03)",
        "b" => "sr.(2000-01-02,2000-01-03)",
        "c" => "nxl.(2000-01-02,2000-01-03)",
        "d" => "nxr.(2000-01-02,2000-01-03)",
        "e" => "adj.(2000-01-02,2000-01-03)",
        "f" => "ov.{x,y}"
      )
    end
  end

  describe "#match" do
    it "applies an eq filter for every key/value pair" do
      builder.match("id" => "1", "done" => "false")
      expect(builder.request.params).to include("id" => "eq.1", "done" => "eq.false")
    end

    it "raises ArgumentError when the query hash is empty" do
      expect { builder.match({}) }.to raise_error(ArgumentError, /at least one/)
    end
  end

  describe "#or_" do
    it "joins under an `or` key wrapped in parentheses" do
      builder.or_("x.eq.1,y.eq.2")
      expect(builder.request.params).to eq("or" => "(x.eq.1,y.eq.2)")
    end

    it "namespaces the OR under the foreign table when reference_table: is supplied" do
      builder.or_("x.eq.1", reference_table: "cities")
      expect(builder.request.params).to eq("cities.or" => "(x.eq.1)")
    end
  end

  describe "#max_affected" do
    it "sets the Prefer header to handling=strict + max-affected when none exists yet" do
      builder.max_affected(5)
      expect(builder.request.headers["Prefer"]).to eq("handling=strict,max-affected=5")
    end

    it "appends handling=strict and max-affected to an existing Prefer header" do
      builder.request.headers["Prefer"] = "return=representation"
      builder.max_affected(10)
      expect(builder.request.headers["Prefer"])
        .to eq("return=representation,handling=strict,max-affected=10")
    end

    it "does not duplicate handling=strict when it is already present" do
      builder.request.headers["Prefer"] = "handling=strict,return=minimal"
      builder.max_affected(3)
      expect(builder.request.headers["Prefer"])
        .to eq("handling=strict,return=minimal,max-affected=3")
    end
  end

  describe "repeated filters on the same column" do
    it "stores subsequent values as an Array so PostgREST sees both query params" do
      builder.lte("x", "a").gte("x", "b")
      expect(builder.request.params["x"]).to eq(["lte.a", "gte.b"])
    end

    it "extends the array on the third and subsequent calls" do
      builder.eq("x", "1").eq("x", "2").eq("x", "3")
      expect(builder.request.params["x"]).to eq(%w[eq.1 eq.2 eq.3])
    end
  end
end
