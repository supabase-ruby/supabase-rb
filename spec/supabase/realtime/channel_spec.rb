# frozen_string_literal: true

require "supabase/realtime"
require "json"

RSpec.describe Supabase::Realtime::Channel do
  let(:socket)  { Supabase::Realtime::TestSocket.new }
  let(:client)  { Supabase::Realtime::Client.new(url: "wss://x/v1", socket: socket) }
  let(:channel) { client.channel("realtime:public:users") }

  before { client.connect }

  # Convenience: have the server reply 'ok' to the most recent join push so the
  # channel transitions to JOINED and any buffered pushes flush.
  def ack_join(status: "ok", response: {})
    join_ref = socket.last_sent_frame["ref"]
    socket.inject(
      "event"    => "phx_reply",
      "topic"    => channel.topic,
      "payload"  => { "status" => status, "response" => response },
      "ref"      => join_ref,
      "join_ref" => join_ref
    )
  end

  describe "#subscribe" do
    it "starts in CLOSED and transitions to JOINING after subscribe()" do
      expect(channel).to be_closed
      channel.subscribe
      expect(channel).to be_joining
    end

    it "sends a phx_join frame with the channel's topic and params" do
      channel.subscribe
      sent = socket.last_sent_frame
      expect(sent["event"]).to eq("phx_join")
      expect(sent["topic"]).to eq("realtime:public:users")
      expect(sent["payload"]).to have_key("config")
    end

    it "transitions to JOINED and fires the SUBSCRIBED callback on phx_reply OK" do
      state = nil
      channel.subscribe { |s, _err| state = s }
      ack_join

      expect(channel).to be_joined
      expect(state).to eq("SUBSCRIBED")
    end

    it "transitions to ERRORED and fires CHANNEL_ERROR on phx_reply error" do
      state = error_payload = nil
      channel.subscribe { |s, err| state = s; error_payload = err }
      ack_join(status: "error", response: { "reason" => "denied" })

      expect(channel).to be_errored
      expect(state).to eq("CHANNEL_ERROR")
      expect(error_payload).to eq("reason" => "denied")
    end

    it "raises AlreadyJoinedError if subscribe() is called twice" do
      channel.subscribe
      expect { channel.subscribe }
        .to raise_error(Supabase::Realtime::Errors::AlreadyJoinedError)
    end
  end

  describe "#on_postgres_changes dispatch" do
    before do
      channel.subscribe
      ack_join
    end

    it "fires the INSERT listener for an INSERT change matching schema+table" do
      received = nil
      channel.on_postgres_changes("INSERT", schema: "public", table: "users") { |p| received = p }

      socket.inject(
        "event"   => "postgres_changes",
        "topic"   => channel.topic,
        "payload" => { "data" => { "type" => "INSERT", "schema" => "public", "table" => "users",
                                   "record" => { "id" => 1 } }, "ids" => [1] }
      )

      expect(received).to be_a(Hash)
      expect(received["data"]["type"]).to eq("INSERT")
    end

    it "fires '*' listeners for INSERT, UPDATE, and DELETE" do
      events = []
      channel.on_postgres_changes("*") { |p| events << p["data"]["type"] }

      %w[INSERT UPDATE DELETE].each do |t|
        socket.inject(
          "event"   => "postgres_changes",
          "topic"   => channel.topic,
          "payload" => { "data" => { "type" => t, "schema" => "public", "table" => "users" } }
        )
      end

      expect(events).to eq(%w[INSERT UPDATE DELETE])
    end

    it "filters out events from a different schema" do
      received = false
      channel.on_postgres_changes("INSERT", schema: "public", table: "users") { received = true }

      socket.inject(
        "event"   => "postgres_changes",
        "topic"   => channel.topic,
        "payload" => { "data" => { "type" => "INSERT", "schema" => "private", "table" => "users" } }
      )

      expect(received).to be false
    end

    it "filters out events from a different table" do
      received = false
      channel.on_postgres_changes("INSERT", schema: "public", table: "users") { received = true }

      socket.inject(
        "event"   => "postgres_changes",
        "topic"   => channel.topic,
        "payload" => { "data" => { "type" => "INSERT", "schema" => "public", "table" => "posts" } }
      )

      expect(received).to be false
    end

    it "rejects unknown event names with ArgumentError" do
      expect { channel.on_postgres_changes("UPSERT") { } }
        .to raise_error(ArgumentError, /INSERT/)
    end
  end

  describe "#on_broadcast dispatch" do
    before { channel.subscribe; ack_join }

    it "fires only the listener whose event name matches the broadcast event" do
      messages = []
      typing   = []
      channel.on_broadcast("message") { |p| messages << p }
      channel.on_broadcast("typing")  { |p| typing   << p }

      socket.inject(
        "event"   => "broadcast",
        "topic"   => channel.topic,
        "payload" => { "event" => "message", "payload" => { "text" => "hi" } }
      )

      expect(messages.length).to eq(1)
      expect(typing).to be_empty
    end
  end

  describe "presence sync via channel dispatch" do
    before { channel.subscribe; ack_join }

    it "routes a presence_state frame through to the channel's Presence object" do
      socket.inject(
        "event"   => "presence_state",
        "topic"   => channel.topic,
        "payload" => { "u1" => { "metas" => [{ "phx_ref" => "r1" }] } }
      )
      expect(channel.presence.state).to include("u1")
    end

    it "applies a presence_diff incrementally" do
      socket.inject(
        "event"   => "presence_state",
        "topic"   => channel.topic,
        "payload" => { "u1" => { "metas" => [{ "phx_ref" => "r1" }] } }
      )
      socket.inject(
        "event"   => "presence_diff",
        "topic"   => channel.topic,
        "payload" => {
          "joins"  => { "u2" => { "metas" => [{ "phx_ref" => "r2" }] } },
          "leaves" => {}
        }
      )

      expect(channel.presence.state.keys).to contain_exactly("u1", "u2")
    end
  end

  describe "#send_broadcast / #track / #untrack" do
    before { channel.subscribe; ack_join; socket.reset_sent_frames }

    it "sends a broadcast frame with type/event/payload nested under payload" do
      channel.send_broadcast("typing", { "user" => "u1" })
      frame = socket.last_sent_frame
      expect(frame["event"]).to eq("broadcast")
      expect(frame["payload"]).to eq("type" => "broadcast", "event" => "typing", "payload" => { "user" => "u1" })
    end

    it "sends a presence/track frame" do
      channel.track({ "status" => "online" })
      expect(socket.last_sent_frame["payload"])
        .to eq("type" => "presence", "event" => "track", "payload" => { "status" => "online" })
    end

    it "sends a presence/untrack frame" do
      channel.untrack
      expect(socket.last_sent_frame["payload"])
        .to eq("type" => "presence", "event" => "untrack")
    end
  end

  describe "phx_close / phx_error inbound" do
    before { channel.subscribe; ack_join }

    it "transitions to CLOSED on phx_close and fires close listeners" do
      fired = nil
      channel.on_close { |p| fired = p }
      socket.inject("event" => "phx_close", "topic" => channel.topic, "payload" => { "reason" => "normal" })

      expect(channel).to be_closed
      expect(fired).to eq("reason" => "normal")
    end

    it "transitions to ERRORED on phx_error and fires error listeners" do
      fired = nil
      channel.on_error { |p| fired = p }
      socket.inject("event" => "phx_error", "topic" => channel.topic, "payload" => { "msg" => "boom" })

      expect(channel).to be_errored
      expect(fired).to eq("msg" => "boom")
    end
  end

  describe "topic isolation" do
    it "ignores messages targeted at a different topic" do
      other = client.channel("realtime:other")
      fired = false
      other.on_postgres_changes("*") { fired = true }

      socket.inject(
        "event"   => "postgres_changes",
        "topic"   => "realtime:public:users", # different topic
        "payload" => { "data" => { "type" => "INSERT" } }
      )

      expect(fired).to be false
    end
  end

  describe "#unsubscribe" do
    before { channel.subscribe; ack_join; socket.reset_sent_frames }

    it "sends a phx_leave frame and marks the channel CLOSED" do
      channel.unsubscribe
      expect(socket.sent_events).to include("phx_leave")
      expect(channel).to be_closed
    end
  end
end
