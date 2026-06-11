# frozen_string_literal: true

require "supabase/realtime"
require "json"
require "logger"
require "stringio"

# US-002: A user callback that raises must not kill the read-loop or block
# delivery to other listeners / other channels on the same client. Mirrors
# `realtime/_async/client.py:113-117` (py logs and continues; rb previously
# bubbled the exception through `on_message` and killed the read thread).
#
# Wrapping lives in {Supabase::Realtime::CallbackSafety} and is applied to
# every user-supplied callback site: channel listeners (broadcast,
# postgres_changes, system, close, error, subscribe), presence hooks
# (sync/join/leave), and Push#receive handlers.
RSpec.describe "US-002: user-callback exceptions are isolated" do
  let(:socket)     { Supabase::Realtime::TestSocket.new }
  let(:log_buffer) { StringIO.new }
  let(:logger)     { Logger.new(log_buffer).tap { |l| l.level = Logger::WARN } }
  let(:client) do
    Supabase::Realtime::Client.new(
      url: "wss://x/v1",
      socket: socket,
      heartbeat_interval: 0,
      auto_reconnect: false,
      logger: logger
    )
  end

  before { client.connect }

  # Convenience: ack the most recent join push (whatever topic it was for).
  def ack_join_for(channel)
    join_ref = JSON.parse(socket.sent_frames.reverse.find { |f| JSON.parse(f)["topic"] == channel.topic })["ref"]
    socket.inject(
      "event"    => "phx_reply",
      "topic"    => channel.topic,
      "payload"  => { "status" => "ok", "response" => {} },
      "ref"      => join_ref,
      "join_ref" => join_ref
    )
  end

  def broadcast_to(channel, event:, payload: {})
    socket.inject(
      "event"   => "broadcast",
      "topic"   => channel.topic,
      "payload" => { "event" => event, "payload" => payload }
    )
  end

  describe "AC #3 — a raising callback does not block subsequent messages on the same channel" do
    it "keeps delivering broadcast frames after the first listener raises" do
      channel = client.channel("public:room")
      channel.subscribe
      ack_join_for(channel)

      received = []
      channel.on_broadcast("message") { |_| raise "boom" }
      channel.on_broadcast("message") { |p| received << p["payload"] }

      broadcast_to(channel, event: "message", payload: { "n" => 1 })
      broadcast_to(channel, event: "message", payload: { "n" => 2 })

      # Both frames must have reached the second listener even though the first
      # listener raised on every dispatch.
      expect(received).to eq([{ "n" => 1 }, { "n" => 2 }])
    end

    it "keeps dispatching postgres_changes after a listener raises" do
      channel = client.channel("public:users")
      channel.subscribe
      ack_join_for(channel)

      seen = []
      channel.on_postgres_changes("*") { |_| raise "boom from listener A" }
      channel.on_postgres_changes("*") { |p| seen << p["data"]["type"] }

      %w[INSERT UPDATE DELETE].each do |t|
        socket.inject(
          "event"   => "postgres_changes",
          "topic"   => channel.topic,
          "payload" => { "data" => { "type" => t } }
        )
      end

      expect(seen).to eq(%w[INSERT UPDATE DELETE])
    end
  end

  describe "AC #4 — a raising callback on channel A does not block channel B" do
    it "still delivers a broadcast to a sibling channel after channel A's listener raises" do
      ch_a = client.channel("public:room_a")
      ch_b = client.channel("public:room_b")
      ch_a.subscribe
      ack_join_for(ch_a)
      ch_b.subscribe
      ack_join_for(ch_b)

      ch_a.on_broadcast("message") { |_| raise "boom in A" }

      received_b = []
      ch_b.on_broadcast("message") { |p| received_b << p["payload"] }

      # First frame goes to A (raises) — must not break the read-loop / dispatch.
      broadcast_to(ch_a, event: "message", payload: { "from" => "a" })
      # Second frame goes to B and must arrive even though A just raised.
      broadcast_to(ch_b, event: "message", payload: { "from" => "b" })

      expect(received_b).to eq([{ "from" => "b" }])
    end
  end

  describe "AC #5 — the injected logger captures the exception" do
    it "logs a warn with the event name and exception class/message" do
      channel = client.channel("public:room")
      channel.subscribe
      ack_join_for(channel)

      channel.on_broadcast("message") { |_| raise ArgumentError, "bad payload" }
      broadcast_to(channel, event: "message", payload: {})

      log = log_buffer.string
      expect(log).to match(/WARN/)
      expect(log).to include("broadcast:message")
      expect(log).to include("ArgumentError")
      expect(log).to include("bad payload")
    end

    it "logs presence_sync exceptions" do
      channel = client.channel("public:room")
      channel.subscribe
      ack_join_for(channel)

      channel.on_presence_sync { raise "presence kaboom" }

      socket.inject(
        "event"   => "presence_state",
        "topic"   => channel.topic,
        "payload" => { "u1" => { "metas" => [{ "phx_ref" => "r1" }] } }
      )

      expect(log_buffer.string).to include("presence_sync")
      expect(log_buffer.string).to include("RuntimeError")
      expect(log_buffer.string).to include("presence kaboom")
    end

    it "logs subscribe-callback exceptions without breaking the JOINED transition" do
      channel = client.channel("public:room")
      channel.subscribe { |_state, _err| raise "subscribe-cb boom" }
      ack_join_for(channel)

      # The exception was swallowed and logged; the channel still transitioned.
      expect(channel).to be_joined
      expect(log_buffer.string).to include("subscribe:SUBSCRIBED")
      expect(log_buffer.string).to include("subscribe-cb boom")
    end

    it "logs push-receive handler exceptions" do
      channel = client.channel("public:room")
      channel.subscribe
      ack_join_for(channel)

      socket.reset_sent_frames
      push = channel.push_event("custom_event", { "k" => "v" })
      push.receive(Supabase::Realtime::Types::AckStatus::OK) { |_| raise "receive boom" }

      ref = JSON.parse(socket.sent_frames.last)["ref"]
      socket.inject(
        "event"    => "phx_reply",
        "topic"    => channel.topic,
        "payload"  => { "status" => "ok", "response" => { "ok" => true } },
        "ref"      => ref,
        "join_ref" => ref
      )

      expect(log_buffer.string).to include("push_receive:ok")
      expect(log_buffer.string).to include("receive boom")
    end
  end

  describe "AC #1/#2 — callbacks across all hook types are wrapped" do
    it "wraps phx_close listener exceptions" do
      channel = client.channel("public:room")
      channel.subscribe
      ack_join_for(channel)

      channel.on_close { |_| raise "close boom" }
      expect {
        socket.inject(
          "event"   => "phx_close",
          "topic"   => channel.topic,
          "payload" => { "reason" => "normal" }
        )
      }.not_to raise_error
      expect(log_buffer.string).to include("phx_close")
      expect(log_buffer.string).to include("close boom")
    end

    it "wraps phx_error listener exceptions" do
      channel = client.channel("public:room")
      channel.subscribe
      ack_join_for(channel)

      channel.on_error { |_| raise "error boom" }
      expect {
        socket.inject(
          "event"   => "phx_error",
          "topic"   => channel.topic,
          "payload" => { "msg" => "x" }
        )
      }.not_to raise_error
      expect(log_buffer.string).to include("phx_error")
      expect(log_buffer.string).to include("error boom")
    end

    it "wraps system listener exceptions" do
      channel = client.channel("public:room")
      channel.subscribe
      ack_join_for(channel)

      channel.on_system { |_| raise "sys boom" }
      expect {
        socket.inject(
          "event"   => "system",
          "topic"   => channel.topic,
          "payload" => { "status" => "ok" }
        )
      }.not_to raise_error
      expect(log_buffer.string).to include("system")
      expect(log_buffer.string).to include("sys boom")
    end

    it "wraps presence_join listener exceptions" do
      channel = client.channel("public:room")
      channel.subscribe
      ack_join_for(channel)

      channel.on_presence_join { |_, _, _| raise "join boom" }

      expect {
        socket.inject(
          "event"   => "presence_state",
          "topic"   => channel.topic,
          "payload" => { "u1" => { "metas" => [{ "phx_ref" => "r1" }] } }
        )
      }.not_to raise_error
      expect(log_buffer.string).to include("presence_join")
      expect(log_buffer.string).to include("join boom")
    end
  end

  describe "fallback behavior when no logger is injected" do
    it "writes via Kernel#warn (stderr) if the client has no logger" do
      bare_socket = Supabase::Realtime::TestSocket.new
      bare_client = Supabase::Realtime::Client.new(
        url: "wss://x/v1", socket: bare_socket,
        heartbeat_interval: 0, auto_reconnect: false
      )
      bare_client.connect
      channel = bare_client.channel("public:room")
      channel.subscribe
      ack_ref = JSON.parse(bare_socket.sent_frames.last)["ref"]
      bare_socket.inject(
        "event"    => "phx_reply",
        "topic"    => channel.topic,
        "payload"  => { "status" => "ok", "response" => {} },
        "ref"      => ack_ref,
        "join_ref" => ack_ref
      )

      channel.on_broadcast("message") { |_| raise "boom" }
      expect {
        bare_socket.inject(
          "event"   => "broadcast",
          "topic"   => channel.topic,
          "payload" => { "event" => "message", "payload" => {} }
        )
      }.to output(/broadcast:message.*RuntimeError.*boom/).to_stderr
    end
  end
end
