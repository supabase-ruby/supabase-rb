# frozen_string_literal: true

require "supabase/realtime"
require "supabase/realtime/sockets/websocket_client_simple"
require "supabase"

# End-to-end coverage for US-012 / F-C8 (part 1): the "works out of the box"
# contract. Before this story, every realtime call site needed to construct a
# transport adapter explicitly and pass it via `socket:`, and `connect` raised
# without one. After US-012:
#
#   - `Realtime::Client.new(url: ...)` constructs the production transport
#     (websocket-client-simple adapter) when neither `transport:` nor `socket:`
#     is supplied.
#   - `channel(...).subscribe` opens the transport on demand and sends the join
#     frame in a single call.
#
# All specs stub `Sockets::WebsocketClientSimple.new` so no real TCP socket is
# opened — the FakeSocket harness from US-007 stands in as a drop-in transport.
RSpec.describe "US-012: Realtime works out of the box (default transport)" do
  let(:fake_transport) { RealtimeSocketHelper::FakeSocket.new }

  before do
    allow(Supabase::Realtime::Sockets::WebsocketClientSimple)
      .to receive(:new).and_return(fake_transport)
  end

  describe "Realtime::Client#initialize" do
    it "accepts a transport: kwarg that overrides default construction (AC #1)" do
      explicit = RealtimeSocketHelper::FakeSocket.new
      client = Supabase::Realtime::Client.new(url: "wss://x/v1", transport: explicit)
      expect(client.socket).to be(explicit)
      expect(Supabase::Realtime::Sockets::WebsocketClientSimple).not_to have_received(:new)
    end

    it "builds the default websocket-client-simple adapter when no transport is given (AC #1)" do
      client = Supabase::Realtime::Client.new(url: "wss://x/v1", params: { apikey: "anon" })
      expect(client.socket).to be(fake_transport)
      expect(Supabase::Realtime::Sockets::WebsocketClientSimple)
        .to have_received(:new).with(url: client.url)
    end

    it "still accepts the legacy socket: kwarg (back compat)" do
      legacy = RealtimeSocketHelper::FakeSocket.new
      client = Supabase::Realtime::Client.new(url: "wss://x/v1", socket: legacy)
      expect(client.socket).to be(legacy)
    end
  end

  describe "#connect" do
    it "no longer raises when no socket was attached — builds the default instead (AC #2)" do
      client = Supabase::Realtime::Client.new(url: "wss://x/v1")
      expect { client.connect }.not_to raise_error
      expect(client.connected?).to be true
    end
  end

  describe "Channel#subscribe" do
    it "auto-connects the transport before pushing the join frame (AC #3)" do
      client = Supabase::Realtime::Client.new(url: "wss://x/v1", params: { apikey: "anon" })
      expect(fake_transport.connected?).to be false

      client.channel("public:users").subscribe

      expect(fake_transport.connected?).to be true
      expect(fake_transport.sent_events).to include("phx_join")
      expect(fake_transport.last_sent_frame).to include(
        "event" => "phx_join",
        "topic" => "realtime:public:users"
      )
    end

    it "does not call connect again if the transport is already connected" do
      client = Supabase::Realtime::Client.new(url: "wss://x/v1", transport: fake_transport)
      client.connect
      expect(fake_transport.connected?).to be true

      # If subscribe blindly called connect again, the fake would re-fire its
      # on_open callbacks (heartbeat restart + rejoin sweep). Prove it doesn't
      # by counting open_callbacks invocations indirectly via the sent events:
      # only one phx_join must hit the wire even after subscribe, not two.
      client.channel("public:users").subscribe
      expect(fake_transport.sent_events.count("phx_join")).to eq(1)
    end
  end

  describe "Supabase.create_client(...) end-to-end (AC #5)" do
    it "subscribe without explicit connect sends the join frame on the wire" do
      umbrella = Supabase.create_client(
        supabase_url: "https://x.supabase.co",
        supabase_key: "anon-key"
      )

      channel = umbrella.realtime.channel("public:users")
      channel.subscribe

      expect(fake_transport.connected?).to be true
      expect(fake_transport.sent_events).to include("phx_join")
      expect(fake_transport.last_sent_frame).to include(
        "event" => "phx_join",
        "topic" => "realtime:public:users"
      )
    end
  end
end
