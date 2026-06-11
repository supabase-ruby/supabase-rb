# frozen_string_literal: true

require "supabase/functions"
require "webmock/rspec"
require "json"

# US-012 — Functions: two missing specs.
#
# AC #1: A user-built Faraday::Connection injected via `http_client:` is the
#        actual transport for `#invoke`. `build_session` must NOT be called,
#        and the injected adapter (here `Faraday::Adapter::Test`) sees every
#        request — proving the client doesn't transparently fall back to a
#        freshly-built session.
#
# AC #2: A caller-supplied `Content-Type` (either via the constructor
#        `headers:` or via the per-invocation `headers:`) wins over the
#        auto-detected value the client sets based on body type
#        (`text/plain` for Strings, `application/json` for Hash/Array).
#        The implementation pins this via `||=` in
#        `lib/supabase/functions/client.rb:106,109` — the spec freezes that
#        contract so a refactor to `=` (or to `merge` in the wrong order)
#        is caught immediately.
RSpec.describe Supabase::Functions::Client, "US-012: Faraday DI + Content-Type priority" do
  let(:base) { "https://x.supabase.co/functions/v1" }

  before { WebMock.disable_net_connect! }
  after  { WebMock.allow_net_connect! }

  # ---------------------------------------------------------------------------
  # AC #1 — custom Faraday connection injection
  # ---------------------------------------------------------------------------

  describe "custom Faraday connection injection (AC #1)" do
    let(:stubs) { Faraday::Adapter::Test::Stubs.new }
    let(:injected_conn) do
      Faraday.new(url: base) { |b| b.adapter :test, stubs }
    end

    it "uses the injected Faraday connection as the transport (no build_session call)" do
      # Guard: if the client silently rebuilt its session, the test adapter
      # wouldn't see the request and WebMock would either intercept it or
      # raise. We assert both that build_session is NOT called AND that the
      # injected stubs see the request.
      expect_any_instance_of(described_class).not_to receive(:build_session)

      stubs.post("/functions/v1/hello") do |env|
        expect(env.request_headers["Authorization"]).to eq("Bearer tok")
        [200, { "Content-Type" => "application/json" }, JSON.generate("ok" => true)]
      end

      client = described_class.new(
        base_url:    base,
        headers:     { "Authorization" => "Bearer tok" },
        http_client: injected_conn
      )

      result = client.invoke("hello", body: { name: "Ada" }, response_type: :json)
      expect(result).to eq("ok" => true)
      stubs.verify_stubbed_calls
    end

    it "does not open any real network connection — even without WebMock the injected adapter would handle it" do
      # WebMock is enabled in the suite-level before-block so this is belt-
      # and-braces, but the assertion encodes intent: an injected adapter is
      # supposed to short-circuit the network entirely.
      stubs.post("/functions/v1/ping") { [200, {}, ""] }

      client = described_class.new(base_url: base, http_client: injected_conn)
      expect { client.invoke("ping") }.not_to raise_error
      stubs.verify_stubbed_calls
    end

    it "keeps verify:/proxy:/timeout: irrelevant when http_client: is supplied (full DI escape hatch)" do
      # The constructor still accepts verify/proxy/timeout kwargs for the
      # default build_session path, but when the caller injects their own
      # Faraday they own the transport config. Pin that by passing values
      # that would normally affect a Faraday build and confirming the
      # injected adapter is what services the call.
      stubs.post("/functions/v1/fn") { [200, {}, ""] }

      client = described_class.new(
        base_url:    base,
        http_client: injected_conn,
        verify:      false,
        proxy:       "http://example-proxy:8080",
        timeout:     1
      )

      expect { client.invoke("fn") }.not_to raise_error
      stubs.verify_stubbed_calls
    end

    it "preserves the injected Faraday across multiple #invoke calls (no per-request rebuild)" do
      # Regression guard: if a future refactor moves session-building into
      # #invoke, the injected connection would be discarded after the first
      # call. Two calls against the same stubs would then go through two
      # different transports — one of which would not be the test adapter.
      stubs.post("/functions/v1/a") { [200, {}, ""] }
      stubs.post("/functions/v1/b") { [200, {}, ""] }

      client = described_class.new(base_url: base, http_client: injected_conn)
      client.invoke("a")
      client.invoke("b")
      stubs.verify_stubbed_calls
    end
  end

  # ---------------------------------------------------------------------------
  # AC #2 — caller-supplied Content-Type wins
  # ---------------------------------------------------------------------------

  describe "user-provided Content-Type priority (AC #2)" do
    let(:client) do
      described_class.new(
        base_url: base,
        headers:  { "Authorization" => "Bearer tok" }
      )
    end

    it "keeps a per-invocation Content-Type over the String→text/plain default" do
      stub = stub_request(:post, "#{base}/fn")
             .with(body: "raw payload",
                   headers: { "Content-Type" => "application/x-www-form-urlencoded" })
             .to_return(status: 200, body: "")

      client.invoke("fn",
                    body:    "raw payload",
                    headers: { "Content-Type" => "application/x-www-form-urlencoded" })
      expect(stub).to have_been_requested
    end

    it "keeps a per-invocation Content-Type over the Hash→application/json default" do
      # Body still goes through JSON.generate (Hash path), but the wire
      # Content-Type is whatever the caller asked for. The relay/edge fn
      # is on the hook for parsing — this is just the header contract.
      stub = stub_request(:post, "#{base}/fn")
             .with(body:    JSON.generate("k" => "v"),
                   headers: { "Content-Type" => "application/vnd.api+json" })
             .to_return(status: 200, body: "")

      client.invoke("fn",
                    body:    { k: "v" },
                    headers: { "Content-Type" => "application/vnd.api+json" })
      expect(stub).to have_been_requested
    end

    it "keeps a per-invocation Content-Type over the Array→application/json default" do
      stub = stub_request(:post, "#{base}/fn")
             .with(body:    JSON.generate([1, 2, 3]),
                   headers: { "Content-Type" => "application/vnd.api+json" })
             .to_return(status: 200, body: "")

      client.invoke("fn",
                    body:    [1, 2, 3],
                    headers: { "Content-Type" => "application/vnd.api+json" })
      expect(stub).to have_been_requested
    end

    it "keeps a constructor-supplied Content-Type over the auto-detected default" do
      # When the caller sets Content-Type at client-construction time it
      # lands in @headers; @headers.merge(per_invocation_headers) puts it
      # into merged_headers before the ||= branch runs. The auto-default
      # must yield.
      pre_typed = described_class.new(
        base_url: base,
        headers:  { "Content-Type" => "application/cbor", "Authorization" => "Bearer tok" }
      )

      stub = stub_request(:post, "#{base}/fn")
             .with(body:    JSON.generate("k" => "v"),
                   headers: { "Content-Type" => "application/cbor" })
             .to_return(status: 200, body: "")

      pre_typed.invoke("fn", body: { k: "v" })
      expect(stub).to have_been_requested
    end

    it "lets a per-invocation Content-Type override the constructor-supplied one (standard merge semantics)" do
      # Sanity check on the merge direction: @headers.merge(headers)
      # — per-invocation takes precedence over constructor. If someone
      # accidentally flipped to headers.merge(@headers), this fails.
      pre_typed = described_class.new(
        base_url: base,
        headers:  { "Content-Type" => "application/cbor", "Authorization" => "Bearer tok" }
      )

      stub = stub_request(:post, "#{base}/fn")
             .with(body:    JSON.generate("k" => "v"),
                   headers: { "Content-Type" => "application/vnd.api+json" })
             .to_return(status: 200, body: "")

      pre_typed.invoke("fn",
                       body:    { k: "v" },
                       headers: { "Content-Type" => "application/vnd.api+json" })
      expect(stub).to have_been_requested
    end

    it "still falls back to the auto-detected Content-Type when the caller passes none (negative guard)" do
      # Without this, an accidental flip from ||= to = would still let the
      # other tests pass IF every test always supplied Content-Type. This
      # pins the default-path so the AC #2 contract is "user value wins
      # WHEN given" — not "user is always required to set CT".
      stub = stub_request(:post, "#{base}/fn")
             .with(body:    JSON.generate("k" => "v"),
                   headers: { "Content-Type" => "application/json" })
             .to_return(status: 200, body: "")

      client.invoke("fn", body: { k: "v" })
      expect(stub).to have_been_requested
    end
  end
end
