# frozen_string_literal: true

require "supabase/realtime"
require "json"

RSpec.describe RealtimeSocketHelper do
  let(:socket) { fake_realtime_socket }

  describe "Socket interface contract" do
    it "satisfies Supabase::Realtime::Socket so it drops into Realtime::Client" do
      expect(socket).to be_a(Supabase::Realtime::Socket)
    end

    it "tracks connected? through connect/close and fires the lifecycle callbacks" do
      opened = closed = false
      socket.on_open  { opened = true }
      socket.on_close { closed = true }

      expect(socket.connected?).to be false
      socket.connect
      expect(socket.connected?).to be true
      expect(opened).to be true

      socket.close
      expect(socket.connected?).to be false
      expect(closed).to be true
    end
  end

  describe "#sent_frames (parsed Hashes per AC)" do
    it "captures every sent payload as a parsed Hash, not the raw JSON string" do
      socket.send(JSON.generate("event" => "phx_join", "topic" => "realtime:public:users"))
      socket.send(JSON.generate("event" => "heartbeat", "topic" => "phoenix"))

      expect(socket.sent_frames).to eq([
        { "event" => "phx_join",  "topic" => "realtime:public:users" },
        { "event" => "heartbeat", "topic" => "phoenix" }
      ])
      expect(socket.sent_frames.first).to be_a(Hash)
    end

    it "exposes last_sent_frame and sent_events for terse assertions" do
      socket.send(JSON.generate("event" => "phx_join", "topic" => "t"))
      socket.send(JSON.generate("event" => "heartbeat", "topic" => "phoenix"))

      expect(socket.last_sent_frame).to eq("event" => "heartbeat", "topic" => "phoenix")
      expect(socket.sent_events).to eq(%w[phx_join heartbeat])
    end

    it "lets reset_sent_frames clear the capture buffer between assertion blocks" do
      socket.send(JSON.generate("event" => "phx_join"))
      socket.reset_sent_frames
      expect(socket.sent_frames).to be_empty
    end
  end

  describe "#simulate_recv (inbound frame helper per AC)" do
    it "accepts a Hash and JSON-encodes it for the message callback" do
      received = []
      socket.on_message { |raw| received << JSON.parse(raw) }

      socket.simulate_recv(event: "phx_reply", topic: "t", payload: { "status" => "ok" })

      expect(received).to eq([
        { "event" => "phx_reply", "topic" => "t", "payload" => { "status" => "ok" } }
      ])
    end

    it "also accepts a raw JSON String for parser-error / malformed-frame specs" do
      received = []
      socket.on_message { |raw| received << raw }

      socket.simulate_recv('{"event":"x"}')
      socket.simulate_recv("not-json")

      expect(received).to eq(['{"event":"x"}', "not-json"])
    end
  end

  describe "drop-in compatibility with Supabase::Realtime::Client" do
    it "captures phx_join via the real channel.subscribe call-path" do
      client  = Supabase::Realtime::Client.new(url: "wss://x/v1", socket: socket)
      client.connect
      channel = client.channel("public:users")
      channel.subscribe

      sent = socket.last_sent_frame
      expect(sent["event"]).to eq("phx_join")
      expect(sent["topic"]).to eq("realtime:public:users")
    end

    it "drives the channel to JOINED via simulate_recv of a phx_reply ok" do
      client  = Supabase::Realtime::Client.new(url: "wss://x/v1", socket: socket)
      client.connect
      channel = client.channel("public:users")
      channel.subscribe

      ref = socket.last_sent_frame["ref"]
      socket.simulate_recv(
        event:    "phx_reply",
        topic:    "realtime:public:users",
        payload:  { "status" => "ok", "response" => {} },
        ref:      ref,
        join_ref: ref
      )

      expect(channel).to be_joined
    end
  end
end
