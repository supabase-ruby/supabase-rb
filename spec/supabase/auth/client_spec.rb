# frozen_string_literal: true

RSpec.describe Supabase::Auth::Client do
  let(:url) { "http://localhost:9999" }
  let(:headers) { { "apikey" => "test-api-key" } }

  describe "#initialize" do
    it "initializes with url and headers" do
      client = described_class.new(url: url, headers: headers)

      expect(client.url).to eq(url)
      expect(client.headers).to eq(headers)
    end

    it "initializes with default options" do
      client = described_class.new(url: url)

      expect(client.auto_refresh_token?).to be true
      expect(client.persist_session?).to be true
      expect(client.detect_session_in_url?).to be true
      expect(client.flow_type).to eq(:implicit)
    end

    it "accepts custom options" do
      client = described_class.new(
        url: url,
        auto_refresh_token: false,
        persist_session: false,
        detect_session_in_url: false,
        flow_type: :pkce
      )

      expect(client.auto_refresh_token?).to be false
      expect(client.persist_session?).to be false
      expect(client.detect_session_in_url?).to be false
      expect(client.flow_type).to eq(:pkce)
    end

    it "accepts a custom http_client option" do
      custom_client = double("http_client")
      client = described_class.new(url: url, http_client: custom_client)

      expect(client).to be_a(described_class)
    end

    it "initializes with empty headers by default" do
      client = described_class.new(url: url)

      expect(client.headers).to eq({})
    end
  end
end
