# frozen_string_literal: true

require "supabase/realtime"
require "json"

# US-018: supabase-py realtime parity cluster (D2/D3/D4/D8 from docs/PARITY.md).
#
# These lock in the behaviors that previously diverged from supabase-py's
# `_async/channel.py` / `_async/client.py`:
#
#   D2 — a phx_error on an already-joined channel must ERROR the channel AND
#        schedule a rejoin (self-heal), not leave it dead until the socket drops.
#   D8 — a `system` frame with status "error" is treated as a channel error
#        (same rejoin path), not delivered to on_system callbacks.
#   D4 — unsubscribe (leave-ack) and a server phx_close remove the channel from
#        the client registry, so it stops receiving dispatch and doesn't leak.
#   D3 — set_auth issued while the socket is briefly offline buffers the
#        access_token push for joined channels and replays it on reconnect,
#        instead of silently dropping it.
RSpec.describe "US-018: realtime parity cluster" do
  let(:socket)  { Supabase::Realtime::TestSocket.new }
  let(:client)  { Supabase::Realtime::Client.new(url: "wss://x/v1", socket: socket, auto_reconnect: false) }
  let(:channel) { client.channel("realtime:public:users") }
  let(:rejoin_timer) { channel.rejoin_timer }

  before { client.connect }

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

  def join_rejoin_thread
    rejoin_timer.instance_variable_get(:@thread)&.join
  end

  describe "D2: phx_error on a joined channel schedules a rejoin" do
    before { channel.subscribe; ack_join }

    it "errors the channel and schedules a rejoin tick" do
      allow(rejoin_timer).to receive(:sleep)

      socket.inject("event" => "phx_error", "topic" => channel.topic, "payload" => { "msg" => "boom" })

      expect(channel).to be_errored
      expect(rejoin_timer.instance_variable_get(:@thread)).not_to be_nil

      join_rejoin_thread
      expect(rejoin_timer.tries).to eq(1)
      # The tick re-issued a phx_join (original subscribe + this rejoin).
      expect(socket.sent_events.count("phx_join")).to eq(2)
    end

    it "still fires user on_error listeners" do
      allow(rejoin_timer).to receive(:sleep)
      fired = nil
      channel.on_error { |p| fired = p }

      socket.inject("event" => "phx_error", "topic" => channel.topic, "payload" => { "msg" => "boom" })

      expect(fired).to eq("msg" => "boom")
    end

    it "is a no-op while LEAVING (a phx_error racing an unsubscribe)" do
      allow(rejoin_timer).to receive(:sleep)
      channel.unsubscribe
      expect(channel).to be_leaving

      socket.inject("event" => "phx_error", "topic" => channel.topic, "payload" => { "msg" => "late" })

      expect(channel).to be_leaving
      expect(rejoin_timer.instance_variable_get(:@thread)).to be_nil
    end
  end

  describe "D8: system frame routing by status" do
    before { channel.subscribe; ack_join }

    it "delivers a status=ok system frame to on_system callbacks" do
      payload = nil
      channel.on_system { |p| payload = p }

      ok = { "status" => "ok", "extension" => "postgres_changes", "message" => "subscribed" }
      socket.inject("event" => "system", "topic" => channel.topic, "payload" => ok)

      expect(payload).to eq(ok)
      expect(channel).to be_joined
    end

    it "treats a status=error system frame as a channel error + rejoin" do
      allow(rejoin_timer).to receive(:sleep)
      system_fired = false
      channel.on_system { system_fired = true }

      err = { "status" => "error", "extension" => "postgres_changes", "message" => "boom" }
      socket.inject("event" => "system", "topic" => channel.topic, "payload" => err)

      expect(system_fired).to be(false)
      expect(channel).to be_errored
      join_rejoin_thread
      expect(rejoin_timer.tries).to eq(1)
    end
  end

  describe "D4: channel is removed from the client registry on close" do
    it "drops the channel after a leave-ack (unsubscribe path)" do
      channel.subscribe
      ack_join
      expect(client.get_channels).to include(channel)

      channel.unsubscribe
      leave_ref = socket.last_sent_frame["ref"]
      socket.inject(
        "event"   => "phx_reply",
        "topic"   => channel.topic,
        "payload" => { "status" => "ok", "response" => {} },
        "ref"     => leave_ref
      )

      expect(channel).to be_closed
      expect(client.get_channels).not_to include(channel)
    end

    it "drops the channel on a server phx_close" do
      channel.subscribe
      ack_join
      socket.inject("event" => "phx_close", "topic" => channel.topic, "payload" => {})

      expect(channel).to be_closed
      expect(client.get_channels).not_to include(channel)
    end

    it "stops dispatching to a channel after it closes" do
      received = 0
      channel.subscribe
      ack_join
      channel.on_broadcast("ping") { received += 1 }

      socket.inject("event" => "phx_close", "topic" => channel.topic, "payload" => {})
      socket.inject(
        "event"   => "broadcast",
        "topic"   => channel.topic,
        "payload" => { "event" => "ping", "payload" => {} }
      )

      expect(received).to eq(0)
    end
  end

  describe "D3: set_auth while offline buffers the access_token for joined channels" do
    it "buffers the rotation and replays it on reconnect" do
      channel.subscribe
      ack_join
      expect(channel).to be_joined

      # Drop the connection (auto_reconnect is off for this client, so no
      # background reconnect races the assertion).
      socket.close
      expect(client.connected?).to be(false)
      socket.reset_sent_frames

      client.set_auth("rotated-offline-jwt")
      # Nothing on the wire yet — the push is buffered.
      expect(socket.sent_events).not_to include("access_token")

      # Reconnect → the buffered access_token frame flushes.
      socket.connect

      access = client.get_channels # channel still tracked (it was JOINED, not closed)
      expect(access).to include(channel)
      sent = socket.sent_frames.map { |f| JSON.parse(f) }
      token_frame = sent.find { |f| f["event"] == "access_token" }
      expect(token_frame).not_to be_nil
      expect(token_frame["payload"]).to eq("access_token" => "rotated-offline-jwt")
    end
  end
end
