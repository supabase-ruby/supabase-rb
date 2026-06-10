# frozen_string_literal: true

require "supabase/storage"
require "faraday"

RSpec.describe Supabase::Storage::Request do
  # Minimal host that mixes in Request and exposes the private _request so we can
  # exercise the precedence rule directly. Mirrors the wiring contract in the
  # Request module's docstring: @session / @base_url / @headers.
  let(:host_class) do
    Class.new do
      include Supabase::Storage::Request

      def initialize(session, base_url, headers)
        @session  = session
        @base_url = base_url
        @headers  = headers
      end

      def call(**kwargs)
        _request(:get, ["thing"], **kwargs)
      end
    end
  end

  let(:base) { "https://x.supabase.co/storage/v1/" }

  # Capture each Faraday request's resolved headers so we can assert what hit the wire.
  let(:captured_headers) { [] }
  let(:session) do
    captured = captured_headers
    Faraday.new(url: base) do |f|
      f.adapter :test do |stub|
        stub.get("/storage/v1/thing") do |env|
          captured << env.request_headers.dup
          [200, { "Content-Type" => "application/json" }, "{}"]
        end
      end
    end
  end

  describe "header precedence (US-038)" do
    it "client @headers override per-call headers on collision (py parity)" do
      host = host_class.new(session, base,
                            { "Authorization" => "Bearer client-tok", "apikey" => "anon" })

      host.call(headers: { "Authorization" => "Bearer per-call-tok",
                           "X-Extra"       => "per-call-only" })

      sent = captured_headers.fetch(0)
      expect(sent["Authorization"]).to eq("Bearer client-tok")
      expect(sent["apikey"]).to eq("anon")
      # Non-colliding per-call headers still ride along.
      expect(sent["X-Extra"]).to eq("per-call-only")
    end

    it "per-call-only headers are preserved when there is no collision" do
      host = host_class.new(session, base, { "apikey" => "anon" })

      host.call(headers: { "Content-Type" => "application/json" })

      sent = captured_headers.fetch(0)
      expect(sent["Content-Type"]).to eq("application/json")
      expect(sent["apikey"]).to eq("anon")
    end

    it "client @headers are sent verbatim when no per-call headers are passed" do
      host = host_class.new(session, base, { "apikey" => "anon" })

      host.call

      sent = captured_headers.fetch(0)
      expect(sent["apikey"]).to eq("anon")
    end
  end
end
