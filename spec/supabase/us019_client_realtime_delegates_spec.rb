# frozen_string_literal: true

require "supabase"

# US-019 — `Supabase::Client` delegates realtime methods so callers can write
# `client.channel("public:users")` instead of `client.realtime.channel(...)`.
# Also pins the "close socket when last channel is removed" contract added on
# `Realtime::Client#remove_channel`.
RSpec.describe Supabase::Client do
  let(:project_url) { "https://abc.supabase.co" }
  let(:key)         { "anon-key" }
  let(:client)      { described_class.new(supabase_url: project_url, supabase_key: key) }

  # Swap in a TestSocket so the umbrella's lazy realtime accessor doesn't try to
  # build the production websocket-client-simple transport (which would attempt
  # a real TCP connect in the close-on-last-channel example).
  let(:fake_socket) { Supabase::Realtime::TestSocket.new }
  let(:fake_realtime) do
    Supabase::Realtime::Client.new(
      url:            "wss://abc.supabase.co/realtime/v1",
      params:         { "apikey" => key, "access_token" => key },
      socket:         fake_socket,
      # Otherwise the close-on-last-channel path triggers the reconnect thread
      # (which sleeps 1s then re-connects the fake socket) and leaves a
      # background thread dangling past the example.
      auto_reconnect: false
    )
  end

  before { client.instance_variable_set(:@realtime, fake_realtime) }

  describe "#channel" do
    it "returns a Realtime::Channel (delegates to client.realtime.channel)" do
      ch = client.channel("public:users")
      expect(ch).to be_a(Supabase::Realtime::Channel)
    end

    it "auto-prefixes 'realtime:' (prefix remains optional)" do
      expect(client.channel("public:users").topic).to eq("realtime:public:users")
      expect(client.channel("realtime:public:users").topic).to eq("realtime:public:users")
    end

    it "registers the channel on the underlying realtime client" do
      ch = client.channel("public:users")
      expect(client.realtime.get_channels).to include(ch)
    end
  end

  describe "#get_channels" do
    it "returns the realtime client's channel list via the umbrella" do
      a = client.channel("a")
      b = client.channel("b")
      expect(client.get_channels.map(&:topic)).to contain_exactly("realtime:a", "realtime:b")
      expect(client.get_channels).to include(a, b)
    end
  end

  describe "#remove_channel" do
    it "removes the channel from #get_channels" do
      a = client.channel("a")
      b = client.channel("b")
      client.remove_channel(a)
      expect(client.get_channels).to contain_exactly(b)
    end

    it "closes the underlying socket once the last channel is removed (AC #3)" do
      fake_realtime.connect
      expect(fake_socket.connected?).to be true

      a = client.channel("a")
      b = client.channel("b")

      client.remove_channel(a)
      expect(fake_socket.connected?).to be(true), "socket should stay open while channels remain"

      client.remove_channel(b)
      expect(client.get_channels).to be_empty
      expect(fake_socket.connected?).to be(false), "socket should close on the last remove_channel"
    end
  end
end
