# frozen_string_literal: true

require "supabase/functions"
require "webmock/rspec"

# US-029 / F-C11 (часть 4) — валидация `region`.
#
# Контракт: {Supabase::Functions::Client#invoke} должен поднять
# {ArgumentError} ещё до сетевого вызова, если переданный `region` не
# принадлежит {Supabase::Functions::Types::FunctionRegion::ALL}.
#
# Этот guard защищает от опечаток (`"us-east"` вместо `"us-east-1"`) и
# случайных значений (`"moon"`), которые бы тихо ушли на сервер в виде
# `x-region` / `forceFunctionRegion` и обернулись бы в HTTP-ошибку только
# на ответе — слишком поздно и без понятного сообщения.
RSpec.describe Supabase::Functions::Client, "region validation (US-029)" do
  let(:base) { "https://x.supabase.co/functions/v1" }
  let(:client) do
    described_class.new(
      base_url: base,
      headers:  { "Authorization" => "Bearer tok", "apikey" => "anon" }
    )
  end

  before { WebMock.disable_net_connect! }
  after  { WebMock.allow_net_connect! }

  describe "invalid region" do
    it "raises ArgumentError for region: \"moon\" (AC #3)" do
      expect { client.invoke("fn", region: "moon") }
        .to raise_error(ArgumentError, /region must be one of/)
    end

    it "raises ArgumentError before issuing any HTTP request" do
      # Если бы сетевой вызов прошёл, WebMock без stub'а упал бы со своей
      # `WebMock::NetConnectNotAllowedError` — но мы хотим именно ArgumentError.
      expect { client.invoke("fn", region: "us-east") } # typo: should be us-east-1
        .to raise_error(ArgumentError, /region must be one of/)
    end

    it "includes the offending region value in the error message" do
      expect { client.invoke("fn", region: "moon") }
        .to raise_error(ArgumentError, /"moon"/)
    end
  end

  describe "valid regions (regression guards)" do
    it "accepts nil region (default — server picks)" do
      stub_request(:post, "#{base}/fn").to_return(status: 200, body: "ok")
      expect { client.invoke("fn", region: nil) }.not_to raise_error
    end

    it "accepts FunctionRegion::ANY without raising and without setting x-region" do
      stub = stub_request(:post, "#{base}/fn").to_return(status: 200, body: "ok")
      expect { client.invoke("fn", region: Supabase::Functions::Types::FunctionRegion::ANY) }
        .not_to raise_error
      # ANY is the "no preference" sentinel — must NOT be forwarded as x-region.
      expect(stub).to have_been_requested
      expect(WebMock).not_to have_requested(:post, "#{base}/fn")
        .with(headers: { "x-region" => "any" })
    end

    it "accepts a concrete enum value (US_EAST_1)" do
      stub_request(:post, "#{base}/fn")
        .with(query:   { "forceFunctionRegion" => "us-east-1" },
              headers: { "x-region" => "us-east-1" })
        .to_return(status: 200, body: "ok")

      expect do
        client.invoke("fn", region: Supabase::Functions::Types::FunctionRegion::US_EAST_1)
      end.not_to raise_error
    end

    it "accepts the bare string equivalent of an enum value" do
      stub_request(:post, "#{base}/fn")
        .with(query:   { "forceFunctionRegion" => "eu-west-1" },
              headers: { "x-region" => "eu-west-1" })
        .to_return(status: 200, body: "ok")

      expect { client.invoke("fn", region: "eu-west-1") }.not_to raise_error
    end
  end

  describe "valid_regions enum exists (AC #2)" do
    it "exposes Types::FunctionRegion::ALL as the list of valid regions" do
      expect(Supabase::Functions::Types::FunctionRegion::ALL).to be_an(Array)
      expect(Supabase::Functions::Types::FunctionRegion::ALL).to be_frozen
      expect(Supabase::Functions::Types::FunctionRegion::ALL)
        .to include(Supabase::Functions::Types::FunctionRegion::ANY,
                    Supabase::Functions::Types::FunctionRegion::US_EAST_1)
    end
  end
end
