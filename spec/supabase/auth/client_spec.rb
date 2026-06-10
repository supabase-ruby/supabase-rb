# frozen_string_literal: true

RSpec.describe Supabase::Auth::Client do
  let(:url) { "http://localhost:9999" }
  let(:headers) { { "apikey" => "test-api-key" } }

  describe "#initialize" do
    it "initializes with url and headers" do
      client = described_class.new(url: url, headers: headers)

      expect(client.url).to eq(url)
      expect(client.headers).to include(headers)
      expect(client.headers["X-Client-Info"]).to match(%r{\Agotrue-rb/})
    end

    it "initializes with default options" do
      client = described_class.new(url: url)

      expect(client._flow_type).to eq("implicit")
      expect(client.admin).to be_a(Supabase::Auth::AdminApi)
      expect(client.mfa).to be_a(Supabase::Auth::MFAApi)
    end

    it "accepts custom options" do
      client = described_class.new(
        url: url,
        auto_refresh_token: false,
        persist_session: false,
        detect_session_in_url: false,
        flow_type: "pkce"
      )

      expect(client._flow_type).to eq("pkce")
    end

    it "accepts a custom http_client option" do
      custom_client = double("http_client")
      client = described_class.new(url: url, http_client: custom_client)

      expect(client).to be_a(described_class)
    end

    it "seeds Constants::DEFAULT_HEADERS (X-Client-Info) when no headers passed" do
      client = described_class.new(url: url)

      expect(client.headers).to eq(Supabase::Auth::Constants::DEFAULT_HEADERS)
      expect(client.headers["X-Client-Info"]).to match(%r{\Agotrue-rb/})
    end

    it "lets caller-supplied headers override the default X-Client-Info" do
      client = described_class.new(url: url, headers: { "X-Client-Info" => "custom/1.0" })

      expect(client.headers["X-Client-Info"]).to eq("custom/1.0")
    end
  end
end
