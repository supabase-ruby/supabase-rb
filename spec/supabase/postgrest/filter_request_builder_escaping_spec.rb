# frozen_string_literal: true

# US-010 (parity-to-py): edge-tests escaping ported from
# supabase-py/src/postgrest/tests/_sync/test_filter_request_builder.py:93-124
# (+ text_search / explain cases from test_request_builder.py:235-267).
#
# The py expectations assert the percent-encoded query string emitted by
# httpx's QueryParams. We mirror them at the Faraday layer using
# WireFormatHelper#expect_query, which inspects the actual `env.url.query`.
#
# Single deliberate divergence is documented inline: `contains(col, Hash)`
# serializes via `JSON.generate` (no whitespace after `:`) instead of py's
# `json.dumps` (space after `:`); both are valid JSON and PostgREST treats
# them identically. Wire bytes differ only in `+%22` (py space) vs nothing
# (rb).

require "supabase/postgrest"

RSpec.describe "PostgREST filter / select wire-format escaping (py-parity)" do
  let(:client) do
    Supabase::Postgrest::Client.new(
      base_url: "https://example.supabase.co/rest/v1",
      headers:  { "apikey" => "anon" }
    )
  end

  def builder
    client.from("example_table").select("*")
  end

  describe "#contains" do
    it "serializes Hash values as JSON (rb: no space after `:`, py-parity at semantic level)" do
      # py: x=cs.%7B%22a%22%3A+%22b%22%7D  (= cs.{"a": "b"} with space)
      # rb: x=cs.%7B%22a%22%3A%22b%22%7D   (= cs.{"a":"b"}  no space)
      # The space-after-colon is a JSON-formatter artefact (json.dumps vs
      # JSON.generate). Both decode to the same Hash; PostgREST parses JSON.
      expect_query(
        builder.contains("x", { "a" => "b" }),
        "select=%2A&x=cs.%7B%22a%22%3A%22b%22%7D"
      )
    end

    it "wraps Array values in PostgREST `{...}` syntax (1:1 with py)" do
      # py test_contains_any_item: x=cs.%7Ba%2Cb%7D
      expect_query(
        builder.contains("x", %w[a b]),
        "select=%2A&x=cs.%7Ba%2Cb%7D"
      )
    end

    it "passes a String through unchanged — caller is responsible for inner JSON shape (1:1 with py)" do
      # py test_contains_in_list: pass-through string '[{"a": "b"}]' → x=cs.%5B%7B%22a%22%3A+%22b%22%7D%5D
      # rb: same — String branch never re-encodes.
      expect_query(
        builder.contains("x", '[{"a": "b"}]'),
        "select=%2A&x=cs.%5B%7B%22a%22%3A+%22b%22%7D%5D"
      )
    end
  end

  describe "#contained_by" do
    it "joins mixed scalar / pre-stringified-array elements with commas inside `{...}` (1:1 with py)" do
      # py test_contained_by_mixed_items:
      #   contained_by("x", ["a", '["b", "c"]']) → x=cd.%7Ba%2C%5B%22b%22%2C+%22c%22%5D%7D
      # rb branch for Array is `value.to_a.join(",")` — same wire output.
      expect_query(
        builder.contained_by("x", ["a", '["b", "c"]']),
        "select=%2A&x=cd.%7Ba%2C%5B%22b%22%2C+%22c%22%5D%7D"
      )
    end
  end

  describe "range operators on date/time bounds" do
    let(:bounds) { ["2000-01-02 08:30", "2000-01-02 09:30"] }

    # py expectations assert that spaces become `+`, `:` becomes `%3A`,
    # `,` becomes `%2C`, parens become `%28`/`%29`. Same here.
    it "range_gt → sr.(...)" do
      expect_query(
        builder.range_gt("x", bounds),
        "select=%2A&x=sr.%282000-01-02+08%3A30%2C2000-01-02+09%3A30%29"
      )
    end

    it "range_gte → nxl.(...)" do
      expect_query(
        builder.range_gte("x", bounds),
        "select=%2A&x=nxl.%282000-01-02+08%3A30%2C2000-01-02+09%3A30%29"
      )
    end

    it "range_lt → sl.(...)" do
      expect_query(
        builder.range_lt("x", bounds),
        "select=%2A&x=sl.%282000-01-02+08%3A30%2C2000-01-02+09%3A30%29"
      )
    end

    it "range_lte → nxr.(...)" do
      expect_query(
        builder.range_lte("x", bounds),
        "select=%2A&x=nxr.%282000-01-02+08%3A30%2C2000-01-02+09%3A30%29"
      )
    end

    it "range_adjacent → adj.(...)" do
      expect_query(
        builder.range_adjacent("x", bounds),
        "select=%2A&x=adj.%282000-01-02+08%3A30%2C2000-01-02+09%3A30%29"
      )
    end
  end

  describe "#overlaps" do
    it "joins an Array of strings inside `{...}` and escapes inner `:` and `,` (1:1 with py)" do
      # py test_overlaps: overlaps("x", ["is:closed", "severity:high"]) →
      #   x=ov.%7Bis%3Aclosed%2Cseverity%3Ahigh%7D
      expect_query(
        builder.overlaps("x", ["is:closed", "severity:high"]),
        "select=%2A&x=ov.%7Bis%3Aclosed%2Cseverity%3Ahigh%7D"
      )
    end

    it "passes through String tstzrange literal unchanged (1:1 with py)" do
      # py test_overlaps_with_timestamp_range:
      #   overlaps("x", "[2000-01-01 12:45, 2000-01-01 13:15)") →
      #     x=ov.%5B2000-01-01+12%3A45%2C+2000-01-01+13%3A15%29
      expect_query(
        builder.overlaps("x", "[2000-01-01 12:45, 2000-01-01 13:15)"),
        "select=%2A&x=ov.%5B2000-01-01+12%3A45%2C+2000-01-01+13%3A15%29"
      )
    end
  end

  describe "#text_search — every (type, config) combination" do
    # py test_text_search only covers (plain, english) in the URL-encoded form;
    # AC #4 asks for *all* combinations, so we enumerate them here. The
    # format is `<type_part>fts<config_part>.<query>` where:
    #   type:    plain → "pl", phrase → "ph", web_search → "w", else → ""
    #   config:  english → "(english)", nil/missing → ""

    it "plain + english → plfts(english).<q>  (matches py test_text_search line 244)" do
      # py: "catchphrase=plfts%28english%29.%27fat%27+%26+%27cat%27"
      expect_query(
        builder.text_search("catchphrase", "'fat' & 'cat'", type: "plain", config: "english"),
        "catchphrase=plfts%28english%29.%27fat%27+%26+%27cat%27&select=%2A"
      )
    end

    it "phrase + english → phfts(english).<q>" do
      expect_query(
        builder.text_search("col", "q", type: "phrase", config: "english"),
        "col=phfts%28english%29.q&select=%2A"
      )
    end

    it "web_search + english → wfts(english).<q>" do
      expect_query(
        builder.text_search("col", "q", type: "web_search", config: "english"),
        "col=wfts%28english%29.q&select=%2A"
      )
    end

    it "no type + english → fts(english).<q>" do
      expect_query(
        builder.text_search("col", "q", config: "english"),
        "col=fts%28english%29.q&select=%2A"
      )
    end

    it "plain + no config → plfts.<q>" do
      expect_query(
        builder.text_search("col", "q", type: "plain"),
        "col=plfts.q&select=%2A"
      )
    end

    it "phrase + no config → phfts.<q>" do
      expect_query(
        builder.text_search("col", "q", type: "phrase"),
        "col=phfts.q&select=%2A"
      )
    end

    it "web_search + no config → wfts.<q>" do
      expect_query(
        builder.text_search("col", "q", type: "web_search"),
        "col=wfts.q&select=%2A"
      )
    end

    it "no type + no config → fts.<q>" do
      expect_query(
        builder.text_search("col", "q"),
        "col=fts.q&select=%2A"
      )
    end

    it "unknown type collapses to bare fts<config_part> (silent fallback, like py)" do
      # py: `elif type_ == "web_search"` chain falls through to `type_part = ""`.
      # rb: `case ... else "" end` — same behaviour. Surfacing as a regression guard.
      expect_query(
        builder.text_search("col", "q", type: "nope", config: "english"),
        "col=fts%28english%29.q&select=%2A"
      )
    end
  end

  describe "#explain — both formats" do
    # py test_explain_plain: default format=text, no options → header contains
    #   "application/vnd.pgrst.plan". py only asserts the prefix; we assert the
    #   exact rb form (which is also a strict superset).
    it "default (format: text, no options) → text plan Accept + ExplainRequestBuilder" do
      b = builder
      result = b.explain
      expect(b.request.headers["Accept"]).to eq("application/vnd.pgrst.plan+text; options=")
      expect(result).to be_a(Supabase::Postgrest::ExplainRequestBuilder)
    end

    # py test_explain_options: format=json + all options on → Accept contains
    #   "application/vnd.pgrst.plan+json;" and "options=analyze|verbose|buffers|wal".
    #   py does NOT cover `settings:` here; the py impl iterates `locals()`,
    #   so any True-valued option is appended in declaration order. We mirror
    #   that order: analyze | verbose | settings | buffers | wal.
    it "format: json + analyze|verbose|buffers|wal → JSON plan Accept + SingleRequestBuilder (1:1 with py)" do
      b = builder
      result = b.explain(format: "json", analyze: true, verbose: true, buffers: true, wal: true)
      expect(b.request.headers["Accept"])
        .to eq("application/vnd.pgrst.plan+json; options=analyze|verbose|buffers|wal")
      expect(result).to be_a(Supabase::Postgrest::SingleRequestBuilder)
    end

    it "format: json with no options → JSON plan Accept (empty options) + SingleRequestBuilder" do
      b = builder
      result = b.explain(format: "json")
      expect(b.request.headers["Accept"]).to eq("application/vnd.pgrst.plan+json; options=")
      expect(result).to be_a(Supabase::Postgrest::SingleRequestBuilder)
    end

    it "format: text + settings: true → text plan Accept with options=settings" do
      # Bonus over py: covers the rb-specific `settings:` kwarg that py also
      # accepts but doesn't test in the URL-form helper.
      b = builder
      b.explain(settings: true)
      expect(b.request.headers["Accept"]).to eq("application/vnd.pgrst.plan+text; options=settings")
    end

    it "preserves option declaration order in the joined string (1:1 with py)" do
      b = builder
      b.explain(format: "json", buffers: true, analyze: true) # mixed order in kwargs
      # rb enumerates `analyze` before `buffers` because it checks each flag in
      # explicit order in the body; matches py's `locals()` iteration order.
      expect(b.request.headers["Accept"])
        .to eq("application/vnd.pgrst.plan+json; options=analyze|buffers")
    end
  end
end
