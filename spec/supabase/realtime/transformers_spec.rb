# frozen_string_literal: true

require "supabase/realtime"

RSpec.describe Supabase::Realtime::Transformers do
  describe ".http_endpoint_url" do
    it "swaps wss:// for https://" do
      expect(described_class.http_endpoint_url("wss://x.supabase.co/realtime/v1"))
        .to eq("https://x.supabase.co/realtime/v1")
    end

    it "swaps ws:// for http:// (local dev)" do
      expect(described_class.http_endpoint_url("ws://localhost:4000/realtime/v1"))
        .to eq("http://localhost:4000/realtime/v1")
    end

    it "strips a trailing /socket/websocket suffix" do
      expect(described_class.http_endpoint_url("wss://x.supabase.co/realtime/v1/socket/websocket"))
        .to eq("https://x.supabase.co/realtime/v1")
    end

    it "strips a trailing /socket suffix" do
      expect(described_class.http_endpoint_url("wss://x.supabase.co/realtime/v1/socket"))
        .to eq("https://x.supabase.co/realtime/v1")
    end

    it "strips a trailing /websocket suffix" do
      expect(described_class.http_endpoint_url("wss://x.supabase.co/realtime/v1/websocket"))
        .to eq("https://x.supabase.co/realtime/v1")
    end

    it "strips trailing slashes after the suffix is removed" do
      expect(described_class.http_endpoint_url("wss://x.supabase.co/realtime/v1/socket/"))
        .to eq("https://x.supabase.co/realtime/v1")
    end

    it "trims trailing slashes even when no suffix matched" do
      expect(described_class.http_endpoint_url("wss://x.supabase.co/realtime/v1///"))
        .to eq("https://x.supabase.co/realtime/v1")
    end

    it "leaves the case of mid-URL components alone (only the leading ws prefix matches)" do
      # Python's `^ws` (IGNORECASE) matches exactly the first 2 chars and replaces with
      # literal "http", so the trailing "S" of "WSS" survives. We mirror that verbatim.
      expect(described_class.http_endpoint_url("WSS://X.Supabase.Co/RealTime/V1"))
        .to eq("httpS://X.Supabase.Co/RealTime/V1")
    end
  end
end
