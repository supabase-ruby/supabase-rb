# frozen_string_literal: true

require "supabase/functions"
require "webmock/rspec"
require "json"

# US-028 / F-C11 (часть 3) — приоритет ошибок HTTP > relay.
#
# Контракт: когда сервер вернул не-2xx статус и *также* выставил relay-заголовок,
# {Supabase::Functions::Client#invoke} обязан поднять {FunctionsHttpError}, а не
# {FunctionsRelayError} — HTTP-ошибка важнее relay-сигнала.
#
# Порядок проверок в {Supabase::Functions::Client#invoke}:
#   1. raise_for_status!  → ловит 4xx / 5xx
#   2. raise_for_relay!   → ловит x-relay-header == "true" (на 2xx)
#
# Если кто-то развернёт порядок обратно — этот spec упадёт.
RSpec.describe Supabase::Functions::Client, "HTTP error precedes relay error (US-028)" do
  let(:base) { "https://x.supabase.co/functions/v1" }
  let(:client) do
    described_class.new(
      base_url: base,
      headers:  { "Authorization" => "Bearer tok", "apikey" => "anon" }
    )
  end

  before { WebMock.disable_net_connect! }
  after  { WebMock.allow_net_connect! }

  describe "500 + x-relay-header" do
    it "raises FunctionsHttpError, not FunctionsRelayError" do
      stub_request(:post, "#{base}/fn").to_return(
        status:  500,
        body:    JSON.generate("error" => "Boom inside the function"),
        headers: { "x-relay-header" => "true" }
      )

      expect { client.invoke("fn") }
        .to raise_error(Supabase::Functions::Errors::FunctionsHttpError) { |err|
          expect(err.message).to eq("Boom inside the function")
          expect(err.status).to eq(500)
        }
    end

    it "raises FunctionsHttpError even when the relay-header payload would otherwise produce a relay message" do
      stub_request(:post, "#{base}/fn").to_return(
        status:  503,
        body:    JSON.generate("error" => "Relay couldn't reach the function"),
        headers: { "x-relay-header" => "true" }
      )

      raised = begin
        client.invoke("fn")
        nil
      rescue StandardError => e
        e
      end

      expect(raised).to be_a(Supabase::Functions::Errors::FunctionsHttpError)
      expect(raised).not_to be_a(Supabase::Functions::Errors::FunctionsRelayError)
    end
  end

  describe "200 + x-relay-error (regression guard)" do
    it "still raises FunctionsRelayError when the HTTP status is OK" do
      # supabase-js detects relay errors via `x-relay-error`; py's `x-relay-header`
      # is a bug we deliberately don't carry.
      stub_request(:post, "#{base}/fn").to_return(
        status:  200,
        body:    JSON.generate("error" => "Relay couldn't reach the function"),
        headers: { "x-relay-error" => "true" }
      )

      expect { client.invoke("fn") }
        .to raise_error(Supabase::Functions::Errors::FunctionsRelayError, /Relay couldn't reach/)
    end
  end
end
