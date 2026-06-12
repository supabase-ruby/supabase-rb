# frozen_string_literal: true

require "supabase"
require "faraday"

# US-011 — Top-level Supabase::Client state-isolation specs.
#
# Three contracts pinned here, so future base_url / ClientOptions / realtime-
# wiring refactors fail loudly instead of silently regressing:
#
#   1. base_url isolation when a custom `http_client:` is shared across sub-
#      clients. py ref: `supabase/tests/_sync/test_client.py:244`
#      (`test_httpx_client_base_url_isolation`, supabase-py issue #1244).
#   2. `ClientOptions#replace` returns a fresh instance and never mutates the
#      receiver. py ref: `supabase/tests/test_client_options.py`.
#   3. Realtime kwargs (`auto_reconnect` / `heartbeat_interval` / `max_retries`
#      / `initial_backoff`) flow from `ClientOptions(realtime: { ... })` into
#      `Realtime::Client.new(...)` and end up on the matching `attr_reader`s.
RSpec.describe "US-011 — Supabase::Client state isolation" do
  let(:project_url) { "https://abc.supabase.co" }
  let(:key)         { "anon-key" }

  # ---------------------------------------------------------------------------
  # AC #1 — base_url isolation when sub-clients share an http_client
  # ---------------------------------------------------------------------------
  #
  # Reproduces the shape of supabase-py's `test_httpx_client_base_url_isolation`
  # (py issue #1244). In py the bug was: a shared `httpx.Client` got its
  # `base_url` rewritten each time a different sub-client (Storage → PostgREST
  # → Functions) was constructed on top of it, so a later request from an
  # earlier sub-client hit the wrong endpoint.
  #
  # In the rb port each sub-client carries its own `base_url` attribute and
  # the injected Faraday connection is only used as a request transport, not
  # as a URL holder. We pin that contract: accessing one sub-client after
  # another must NOT mutate any other sub-client's `base_url`.
  describe "base_url isolation with a shared http_client (AC #1)" do
    let(:shared_faraday) { Faraday.new }

    def make_client
      opts = Supabase::ClientOptions.new(http_client: shared_faraday)
      Supabase::Client.new(supabase_url: project_url, supabase_key: key, options: opts)
    end

    it "every sub-client carries the correct, distinct base_url even when http_client is shared" do
      client = make_client

      expect(client.postgrest.base_url).to eq("#{project_url}/rest/v1")
      expect(client.storage.base_url).to   eq("#{project_url}/storage/v1/")
      expect(client.functions.base_url).to eq("#{project_url}/functions/v1")
    end

    it "accessing PostgREST after Storage does NOT mutate Storage#base_url (py issue #1244)" do
      client = make_client

      storage_before = client.storage.base_url
      expect(storage_before).to end_with("/storage/v1/")

      # The py bug surfaced here: instantiating the next sub-client over the
      # same transport rewrote the shared client's base_url, and a follow-up
      # Storage call would 404 against /rest/v1/... instead of /storage/v1/...
      _ = client.postgrest.base_url

      expect(client.storage.base_url).to eq(storage_before)
    end

    it "accessing Functions after PostgREST/Storage does NOT mutate either of their base_urls" do
      client = make_client

      pg_before = client.postgrest.base_url
      st_before = client.storage.base_url

      _ = client.functions.base_url

      expect(client.postgrest.base_url).to eq(pg_before)
      expect(client.storage.base_url).to   eq(st_before)
    end

    it "the shared Faraday connection is the actual transport for every sub-client" do
      client = make_client

      # Sanity guard: if a future refactor stops sharing the injected Faraday,
      # the spec above stops being a meaningful base_url-isolation test.
      expect(client.postgrest.instance_variable_get(:@http_client)).to be(shared_faraday)
      expect(client.storage.instance_variable_get(:@session)).to       be(shared_faraday)
      expect(client.functions.instance_variable_get(:@session)).to     be(shared_faraday)
    end
  end

  # ---------------------------------------------------------------------------
  # AC #2 — ClientOptions#replace returns a copy, never mutates the receiver
  # ---------------------------------------------------------------------------
  #
  # Mirrors py `test_replace_returns_updated_options` /
  # `test_replace_updates_only_new_options` in
  # `supabase/tests/test_client_options.py`. py uses a frozen dataclass so
  # mutation isn't even possible; rb uses a plain class with attr_accessors,
  # so this is the only thing pinning the "replace = copy-on-write" contract.
  describe "ClientOptions#replace immutability (AC #2)" do
    it "returns a brand-new ClientOptions instance (object identity)" do
      original = Supabase::ClientOptions.new(schema: "public")
      derived  = original.replace(schema: "private")

      expect(derived).to be_a(Supabase::ClientOptions)
      expect(derived).not_to equal(original)
    end

    it "applies overrides on the copy without touching the original's fields" do
      original = Supabase::ClientOptions.new(
        schema: "public", auto_refresh_token: true, flow_type: "pkce"
      )

      derived = original.replace(schema: "private", auto_refresh_token: false)

      # Copy has overrides
      expect(derived.schema).to             eq("private")
      expect(derived.auto_refresh_token).to be false
      # Unmentioned fields carry over unchanged
      expect(derived.flow_type).to eq("pkce")
      # Original is untouched on every overridden field
      expect(original.schema).to             eq("public")
      expect(original.auto_refresh_token).to be true
      expect(original.flow_type).to          eq("pkce")
    end

    it "mutating the returned copy's headers does not bleed back into the original" do
      original = Supabase::ClientOptions.new(headers: { "X-Tenant" => "acme" })
      derived  = original.replace

      # `replace` with no args should still produce a new instance whose
      # headers Hash is at least as isolated as the post-`replace` write
      # surface — `derived.headers["..."] = ...` must not show up in
      # `original.headers`. (`ClientOptions#new` copies DEFAULT_HEADERS into a
      # fresh Hash via `merge`, so the contract holds for any rebuilt-from-
      # to_h instance.)
      derived.headers["X-Tenant"] = "globex"

      expect(original.headers["X-Tenant"]).to eq("acme")
      expect(derived.headers["X-Tenant"]).to  eq("globex")
    end

    it "round-trips every field through to_h → new(**to_h) with no field loss" do
      original = Supabase::ClientOptions.new(
        schema: "ledger",
        headers: { "X-Tenant" => "acme" },
        auto_refresh_token: false,
        persist_session: false,
        postgrest_client_timeout: 30,
        storage_client_timeout:   40,
        function_client_timeout:  50,
        flow_type: "implicit"
      )

      derived = original.replace

      expect(derived.to_h).to eq(original.to_h)
      expect(derived).not_to equal(original)
    end
  end

  # ---------------------------------------------------------------------------
  # AC #3 — Realtime kwargs flow through ClientOptions(realtime: { ... })
  # ---------------------------------------------------------------------------
  #
  # `Supabase::Client#realtime` builds a fresh `Realtime::Client` with
  # `**sub_options(:realtime)`. When the umbrella receives a ClientOptions
  # struct, `sub_options(:realtime)` resolves to `o.realtime.transform_keys(
  # &:to_sym)`. This spec proves every realtime knob the PRD calls out
  # (`auto_reconnect`, `heartbeat_interval`, `max_retries`, `initial_backoff`)
  # reaches the matching `attr_reader` on the realtime sub-client.
  #
  # We don't connect the socket — the default transport is constructed at
  # `Realtime::Client#initialize` but never opens a TCP connection until
  # `.connect`, so it's safe to read the attrs straight after instantiation.
  describe "realtime kwargs pass-through from ClientOptions (AC #3)" do
    let(:realtime_opts) do
      {
        auto_reconnect:     false,
        heartbeat_interval: 17,
        max_retries:        9,
        initial_backoff:    2.5
      }
    end

    it "ClientOptions(realtime: {...}) plumbs every kwarg into Realtime::Client attrs" do
      opts = Supabase::ClientOptions.new(realtime: realtime_opts)
      client = Supabase::Client.new(supabase_url: project_url, supabase_key: key, options: opts)

      rt = client.realtime
      expect(rt.auto_reconnect).to     be false
      expect(rt.heartbeat_interval).to eq(17)
      expect(rt.max_retries).to        eq(9)
      expect(rt.initial_backoff).to    eq(2.5)
    end

    it "string-keyed realtime hash works too (symbol coercion via sub_options)" do
      opts = Supabase::ClientOptions.new(realtime: realtime_opts.transform_keys(&:to_s))
      client = Supabase::Client.new(supabase_url: project_url, supabase_key: key, options: opts)

      rt = client.realtime
      expect(rt.auto_reconnect).to     be false
      expect(rt.heartbeat_interval).to eq(17)
      expect(rt.max_retries).to        eq(9)
      expect(rt.initial_backoff).to    eq(2.5)
    end

    it "when realtime: is not provided the Realtime::Client picks up its own defaults" do
      client = Supabase::Client.new(supabase_url: project_url, supabase_key: key, options: {})

      rt = client.realtime
      expect(rt.auto_reconnect).to     be true
      expect(rt.max_retries).to        eq(5)
      expect(rt.initial_backoff).to    eq(1.0)
      expect(rt.heartbeat_interval).to eq(Supabase::Realtime::Types::DEFAULT_HEARTBEAT_INTERVAL_SECONDS)
    end

    it "plain Hash shape (options[:realtime]) also threads kwargs through" do
      # `{ realtime: {...} }` without legacy-only keys (:auth/:postgrest/
      # :functions/:global) is canonicalized into ClientOptions — :realtime
      # alone is not a legacy marker. Same kwargs must still reach the
      # realtime client via `options_from_struct(:realtime)`.
      client = Supabase::Client.new(
        supabase_url: project_url, supabase_key: key,
        options: { realtime: realtime_opts }
      )

      rt = client.realtime
      expect(rt.auto_reconnect).to     be false
      expect(rt.heartbeat_interval).to eq(17)
      expect(rt.max_retries).to        eq(9)
      expect(rt.initial_backoff).to    eq(2.5)
    end
  end
end
