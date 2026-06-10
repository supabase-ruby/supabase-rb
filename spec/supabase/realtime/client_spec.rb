# frozen_string_literal: true

require "supabase/realtime"
require "json"

RSpec.describe Supabase::Realtime::Client do
  let(:socket) { Supabase::Realtime::TestSocket.new }
  let(:client) do
    described_class.new(
      url: "wss://x.supabase.co/realtime/v1",
      params: { apikey: "anon" },
      socket: socket
    )
  end

  describe "URL normalization" do
    it "appends /websocket and the protocol version + params as the query string" do
      expect(client.url).to include("wss://x.supabase.co/realtime/v1/websocket")
      expect(client.url).to include("vsn=1.0.0")
      expect(client.url).to include("apikey=anon")
    end

    it "upgrades http(s) URLs to ws(s) so callers can paste the project URL as-is" do
      c = described_class.new(url: "https://x.supabase.co/realtime/v1", socket: socket)
      expect(c.url).to start_with("wss://")

      c2 = described_class.new(url: "http://localhost:4000", socket: socket)
      expect(c2.url).to start_with("ws://")
    end

    it "does not double-append /websocket if the caller already included it" do
      c = described_class.new(url: "wss://x/v1/websocket", socket: socket)
      expect(c.url.scan("/websocket").length).to eq(1)
    end
  end

  describe "#connect / #disconnect / #connected?" do
    it "delegates the lifecycle to the underlying socket" do
      expect(client.connected?).to be false
      client.connect
      expect(client.connected?).to be true
      client.disconnect
      expect(client.connected?).to be false
    end

    it "auto-constructs a default transport when none is provided (US-012)" do
      # US-012 changed `connect` from raising "no socket attached" to building a
      # default Sockets::WebsocketClientSimple lazily. Stub the class so the
      # spec doesn't open a real TCP socket — we only need to assert the
      # construction path.
      require "supabase/realtime/sockets/websocket_client_simple"
      fake = Supabase::Realtime::TestSocket.new
      allow(Supabase::Realtime::Sockets::WebsocketClientSimple)
        .to receive(:new).and_return(fake)

      bare = described_class.new(url: "wss://x")
      expect(bare.socket).to be(fake)
      bare.connect
      expect(bare.connected?).to be true
    end
  end

  describe "#use_socket" do
    it "swaps in a socket after construction" do
      bare = described_class.new(url: "wss://x", socket: Supabase::Realtime::TestSocket.new)
      bare.use_socket(socket)
      bare.connect
      expect(bare.connected?).to be true
      expect(bare.socket).to be(socket)
    end
  end

  describe "#channel" do
    it "returns a new Channel instance for every call, even with the same topic (US-014, parity with supabase-py)" do
      a = client.channel("topic:1")
      b = client.channel("topic:1")
      expect(a).not_to be(b)
      expect(a.topic).to eq(b.topic)
    end

    it "tracks channels in #get_channels" do
      client.channel("topic:1")
      client.channel("topic:2")
      expect(client.get_channels.map(&:topic))
        .to contain_exactly("realtime:topic:1", "realtime:topic:2")
    end

    it "exposes multiple channels per topic via #get_channels (US-014)" do
      a = client.channel("topic:1")
      b = client.channel("topic:1")
      expect(client.get_channels).to contain_exactly(a, b)
    end

    it "auto-prefixes 'realtime:' for parity with supabase-py" do
      ch = client.channel("public:users")
      expect(ch.topic).to eq("realtime:public:users")
    end

    it "leaves topics that already start with 'realtime:' alone" do
      ch = client.channel("realtime:public:users")
      expect(ch.topic).to eq("realtime:public:users")
    end
  end

  describe "#remove_channel / #remove_all_channels" do
    before { client.connect }

    it "removes a single channel and emits its phx_leave" do
      ch = client.channel("topic:1")
      ch.subscribe
      client.remove_channel(ch)
      expect(client.get_channels).to be_empty
      expect(socket.sent_events).to include("phx_leave")
    end

    it "clears every channel with #remove_all_channels" do
      client.channel("a").subscribe
      client.channel("b").subscribe
      client.remove_all_channels
      expect(client.get_channels).to be_empty
    end
  end

  describe "#next_ref" do
    it "returns monotonically increasing string refs (so server replies map back uniquely)" do
      refs = Array.new(3) { client.next_ref }
      expect(refs).to eq(%w[1 2 3])
    end
  end

  describe "#set_auth" do
    before do
      client.connect
      ch = client.channel("realtime:public:users")
      ch.subscribe
      socket.inject(
        "event" => "phx_reply", "topic" => ch.topic,
        "payload" => { "status" => "ok", "response" => {} },
        "ref" => socket.last_sent_frame["ref"]
      )
      socket.reset_sent_frames
    end

    it "stores the new token AND pushes an access_token frame to every joined channel" do
      client.set_auth("new-jwt")
      expect(client.access_token).to eq("new-jwt")

      frame = socket.last_sent_frame
      expect(frame["event"]).to eq("access_token")
      expect(frame["topic"]).to eq("realtime:public:users")
      expect(frame["payload"]).to eq("access_token" => "new-jwt")
    end
  end

  describe "#send_heartbeat" do
    before { client.connect }

    it "sends a heartbeat frame targeted at the special 'phoenix' topic" do
      client.send_heartbeat
      frame = socket.last_sent_frame
      expect(frame["event"]).to eq("heartbeat")
      expect(frame["topic"]).to eq("phoenix")
    end

    it "is a no-op when the socket isn't connected" do
      client.disconnect
      socket.reset_sent_frames
      client.send_heartbeat
      expect(socket.sent_frames).to be_empty
    end
  end

  describe "inbound dispatch" do
    before do
      client.connect
      @ch1 = client.channel("topic:1")
      @ch2 = client.channel("topic:2")
      @ch1.subscribe
      @ch2.subscribe
    end

    it "routes a frame only to the channel whose topic matches" do
      hit1 = hit2 = false
      @ch1.on_broadcast("e") { hit1 = true }
      @ch2.on_broadcast("e") { hit2 = true }

      socket.inject(
        "event"   => "broadcast", "topic" => "realtime:topic:1",
        "payload" => { "event" => "e", "payload" => {} }
      )

      expect(hit1).to be true
      expect(hit2).to be false
    end

    it "silently drops frames with no topic (server housekeeping pings, etc.)" do
      expect { socket.inject("event" => "phx_close", "payload" => {}) }.not_to raise_error
    end
  end

  describe "send_buffer (offline pushes)" do
    it "buffers frames pushed before the socket connects and flushes them on open" do
      # US-012 made `channel.subscribe` auto-connect, so we drive Client#push
      # directly to exercise the offline-buffering path (still used by
      # channel.send_broadcast / push_event between an unexpected close and
      # the auto-reconnect).
      msg = Supabase::Realtime::Message.new(
        event: "broadcast", topic: "realtime:topic:buffer", payload: { "x" => 1 },
        ref: "1", join_ref: "1"
      )
      client.push(msg)
      expect(socket.sent_frames).to be_empty

      client.connect
      events = socket.sent_frames.map { |f| JSON.parse(f)["event"] }
      expect(events).to include("broadcast")
    end
  end
end
