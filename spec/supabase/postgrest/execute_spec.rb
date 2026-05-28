# frozen_string_literal: true

require "supabase/postgrest"
require "webmock/rspec"
require "json"

RSpec.describe "Postgrest end-to-end execute" do
  let(:base) { "https://example.supabase.co/rest/v1" }
  let(:users_url) { %r{\Ahttps://example\.supabase\.co/rest/v1/users(\?.*)?\z} }
  let(:rpc_url)   { %r{\Ahttps://example\.supabase\.co/rest/v1/rpc/[^?]+(\?.*)?\z} }

  let(:client) do
    Supabase::Postgrest::Client.new(
      base_url: base,
      headers:  { "apikey" => "anon", "Authorization" => "Bearer tok" }
    )
  end

  before { WebMock.disable_net_connect! }
  after  { WebMock.allow_net_connect! }

  # ---------------------------------------------------------------------------
  # APIResponse plumbing
  # ---------------------------------------------------------------------------

  describe "APIResponse" do
    it "parses an array body into .data" do
      stub_request(:get, users_url)
        .to_return(status: 200, body: JSON.generate([{ "id" => 1, "name" => "a" }]),
                   headers: { "Content-Type" => "application/json" })

      resp = client.from("users").select("id", "name").execute
      expect(resp).to be_a(Supabase::Postgrest::APIResponse)
      expect(resp.data).to eq([{ "id" => 1, "name" => "a" }])
      expect(resp.count).to be_nil
    end

    it "populates .count from the Content-Range header when count: was requested" do
      stub_request(:get, users_url).to_return(
        status:  200,
        body:    JSON.generate([{ "id" => 1 }, { "id" => 2 }]),
        headers: { "Content-Type" => "application/json", "Content-Range" => "0-1/2" }
      )

      resp = client.from("users").select("*", count: "exact").execute
      expect(resp.count).to eq(2)
    end

    it "returns nil count when Content-Range is `*/*` (PostgREST shorthand for unknown)" do
      stub_request(:get, users_url).to_return(
        status: 200, body: JSON.generate([]),
        headers: { "Content-Range" => "*/*" }
      )

      resp = client.from("users").select("*", count: "exact").execute
      expect(resp.count).to be_nil
    end

    it "ignores Content-Range when no count Prefer was sent" do
      stub_request(:get, users_url).to_return(
        status: 200, body: JSON.generate([]),
        headers: { "Content-Range" => "0-9/100" }
      )

      resp = client.from("users").select("*").execute
      expect(resp.count).to be_nil
    end

    it "returns [] when the body is empty (e.g. HEAD or DELETE returning=minimal)" do
      stub_request(:head, users_url).to_return(status: 200, body: "")
      resp = client.from("users").select("*", head: true).execute
      expect(resp.data).to eq([])
    end

    it "falls back to the raw body string when it cannot be parsed as JSON" do
      stub_request(:get, users_url).to_return(status: 200, body: "not json")
      resp = client.from("users").select("*").execute
      expect(resp.data).to eq("not json")
    end
  end

  # ---------------------------------------------------------------------------
  # Error mapping
  # ---------------------------------------------------------------------------

  describe "error responses" do
    it "raises APIError with the parsed body when PostgREST returns 4xx" do
      stub_request(:get, users_url).to_return(
        status: 400,
        body:   JSON.generate("message" => "bad", "code" => "PGRST100",
                              "hint" => "h", "details" => "d")
      )

      expect { client.from("users").select("*").execute }
        .to raise_error(Supabase::Postgrest::Errors::APIError) { |err|
          expect(err.message).to eq("bad")
          expect(err.code).to eq("PGRST100")
        }
    end

    it "synthesizes an APIError when the error body isn't valid JSON" do
      stub_request(:get, users_url).to_return(status: 502, body: "Bad Gateway")

      expect { client.from("users").select("*").execute }
        .to raise_error(Supabase::Postgrest::Errors::APIError) { |err|
          expect(err.message).to eq("JSON could not be generated")
          expect(err.code).to eq("502")
        }
    end
  end

  # ---------------------------------------------------------------------------
  # Retry logic — 503/520 on safe verbs only, max 3 attempts, exp backoff
  # ---------------------------------------------------------------------------

  describe "retry behavior" do
    before { allow_any_instance_of(Object).to receive(:sleep) }

    it "retries idempotent GETs on 503 until success" do
      attempts = 0
      stub_request(:get, users_url).to_return do
        attempts += 1
        if attempts < 3
          { status: 503, body: "" }
        else
          { status: 200, body: JSON.generate([{ "id" => attempts }]) }
        end
      end

      resp = client.from("users").select("*").execute
      expect(resp.data).to eq([{ "id" => 3 }])
      expect(attempts).to eq(3)
    end

    it "does NOT retry on POST (writes are unsafe)" do
      attempts = 0
      stub_request(:post, users_url).to_return do
        attempts += 1
        { status: 503, body: JSON.generate("message" => "down", "code" => "503") }
      end

      expect { client.from("users").insert({ "k" => "v" }).execute }
        .to raise_error(Supabase::Postgrest::Errors::APIError)
      expect(attempts).to eq(1)
    end

    it "stops retrying when retry(false) is set explicitly" do
      attempts = 0
      stub_request(:get, users_url).to_return do
        attempts += 1
        { status: 503, body: JSON.generate("message" => "x", "code" => "503") }
      end

      expect { client.from("users").select("*").retry(false).execute }
        .to raise_error(Supabase::Postgrest::Errors::APIError)
      expect(attempts).to eq(1)
    end
  end

  # ---------------------------------------------------------------------------
  # Result-shape switchers
  # ---------------------------------------------------------------------------

  describe "#single" do
    it "returns a SingleAPIResponse with the parsed single object" do
      stub_request(:get, users_url).to_return(
        status: 200, body: JSON.generate("id" => 1, "name" => "a"),
        headers: { "Content-Type" => "application/json" }
      )

      resp = client.from("users").select("*").single.execute
      expect(resp).to be_a(Supabase::Postgrest::SingleAPIResponse)
      expect(resp.data).to eq("id" => 1, "name" => "a")
    end
  end

  describe "#maybe_single" do
    it "returns nil when the array body is empty" do
      stub_request(:get, users_url).to_return(status: 200, body: "[]")
      resp = client.from("users").select("*").maybe_single.execute
      expect(resp).to be_nil
    end

    it "unwraps a single-row array into a SingleAPIResponse" do
      stub_request(:get, users_url).to_return(status: 200, body: JSON.generate([{ "id" => 1 }]))

      resp = client.from("users").select("*").maybe_single.execute
      expect(resp).to be_a(Supabase::Postgrest::SingleAPIResponse)
      expect(resp.data).to eq("id" => 1)
    end

    it "raises APIError when more than one row comes back" do
      stub_request(:get, users_url)
        .to_return(status: 200, body: JSON.generate([{ "id" => 1 }, { "id" => 2 }]))

      expect { client.from("users").select("*").maybe_single.execute }
        .to raise_error(Supabase::Postgrest::Errors::APIError) { |err|
          expect(err.message).to include("Cannot coerce")
          expect(err.details).to include("more than one row")
          expect(err.code).to eq("406")
        }
    end
  end

  describe "#csv" do
    it "returns the raw CSV body as a string" do
      csv = "id,name\n1,a\n2,b\n"
      stub_request(:get, users_url).to_return(status: 200, body: csv)

      resp = client.from("users").select("*").csv.execute
      expect(resp.data).to eq(csv)
    end
  end

  describe "#explain (text format)" do
    it "returns the EXPLAIN plan body verbatim, not a parsed APIResponse" do
      plan = "Seq Scan on users  (cost=0.00..1.00 rows=1 width=4)"
      stub_request(:get, users_url).to_return(status: 200, body: plan)

      out = client.from("users").select("*").explain(format: "text").execute
      expect(out).to eq(plan)
    end
  end

  # ---------------------------------------------------------------------------
  # Full CRUD round-trips
  # ---------------------------------------------------------------------------

  describe "CRUD round-trips" do
    it "POSTs the row body and returns the inserted record" do
      stub_request(:post, users_url)
        .with(
          body:    JSON.generate("name" => "Ada"),
          headers: { "Authorization" => "Bearer tok" }
        )
        .to_return(status: 201, body: JSON.generate([{ "id" => 1, "name" => "Ada" }]))

      resp = client.from("users").insert({ "name" => "Ada" }).execute
      expect(resp.data).to eq([{ "id" => 1, "name" => "Ada" }])
    end

    it "PATCHes with filter+select chained" do
      stub_request(:patch, users_url)
        .with(body: JSON.generate("name" => "Ada Lovelace"))
        .to_return(status: 200, body: JSON.generate([{ "id" => 1, "name" => "Ada Lovelace" }]))

      resp = client.from("users")
                   .update({ "name" => "Ada Lovelace" })
                   .eq("id", 1)
                   .select("id,name")
                   .execute

      expect(resp.data.first["name"]).to eq("Ada Lovelace")
    end

    it "DELETEs with filter and returns deleted rows when Prefer=return=representation" do
      stub_request(:delete, users_url).to_return(status: 200, body: JSON.generate([{ "id" => 1 }]))

      resp = client.from("users").delete.eq("id", 1).execute
      expect(resp.data).to eq([{ "id" => 1 }])
    end

    it "RPC POSTs the params as the JSON body" do
      stub_request(:post, rpc_url)
        .with(body: JSON.generate("x" => 41))
        .to_return(status: 200, body: JSON.generate(42))

      resp = client.rpc("inc_by", { x: 41 }).execute
      expect(resp.data).to eq(42)
    end
  end
end
