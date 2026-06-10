# frozen_string_literal: true

require "supabase/realtime"

# US-011: Channel uses Timer for rejoin (F-C7 part 2).
#
# The channel owns a {Supabase::Realtime::Timer} (introduced in US-010) and
# schedules a tick on it whenever the join handshake errors or times out.
# A successful JOINED reply resets the timer so the backoff curve starts over
# next time. When the tick fires, it re-invokes `rejoin`, which sends a fresh
# phx_join frame.
#
# These specs stub `sleep` on the rejoin timer instance so ticks are
# deterministic (no real wall-clock waiting) and then join the timer's worker
# thread so the assertion is observed after the rejoin push actually lands.
RSpec.describe Supabase::Realtime::Channel, "rejoin timer (US-011)" do
  let(:socket)  { Supabase::Realtime::TestSocket.new }
  let(:client)  { Supabase::Realtime::Client.new(url: "wss://x/v1", socket: socket) }
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

  describe "#initialize" do
    it "creates a rejoin Timer with tries=0 and no pending tick" do
      expect(rejoin_timer).to be_a(Supabase::Realtime::Timer)
      expect(rejoin_timer.tries).to eq(0)
      expect(rejoin_timer.instance_variable_get(:@thread)).to be_nil
    end
  end

  describe "on join error (phx_reply with status=error)" do
    it "schedules a rejoin tick instead of leaving the channel idle in ERRORED" do
      allow(rejoin_timer).to receive(:sleep)

      channel.subscribe
      ack_join(status: "error", response: { "reason" => "denied" })

      expect(channel).to be_errored
      expect(rejoin_timer.instance_variable_get(:@thread)).not_to be_nil

      join_rejoin_thread
      expect(rejoin_timer.tries).to eq(1)
    end

    it "re-issues a phx_join frame when the scheduled tick fires" do
      allow(rejoin_timer).to receive(:sleep)

      channel.subscribe
      ack_join(status: "error", response: { "reason" => "denied" })
      join_rejoin_thread

      # First phx_join was the original subscribe(); the second is the rejoin
      # the timer scheduled in response to the error reply.
      expect(socket.sent_events.count("phx_join")).to eq(2)
      expect(socket.last_sent_frame["event"]).to eq("phx_join")
      expect(socket.last_sent_frame["topic"]).to eq("realtime:public:users")
      expect(channel).to be_joining
    end
  end

  describe "on join timeout" do
    it "schedules a rejoin tick when the join push times out" do
      allow(rejoin_timer).to receive(:sleep)

      channel.subscribe
      # Resolve the join push as TIMEOUT — same code path the Push timeout thread
      # would hit in production. Goes through on_join_timeout directly.
      channel.join_push.send(:resolve, status: "timeout", payload: {})

      expect(channel).to be_errored
      join_rejoin_thread
      expect(rejoin_timer.tries).to eq(1)
    end

    it "re-issues a phx_join frame when the scheduled tick fires" do
      allow(rejoin_timer).to receive(:sleep)

      channel.subscribe
      channel.join_push.send(:resolve, status: "timeout", payload: {})
      join_rejoin_thread

      expect(socket.sent_events.count("phx_join")).to eq(2)
      expect(socket.last_sent_frame["event"]).to eq("phx_join")
    end
  end

  describe "on successful JOINED" do
    it "resets the rejoin timer so the next failure starts the backoff at 0" do
      allow(rejoin_timer).to receive(:sleep)

      # Fail once → tries advances to 1.
      channel.subscribe
      ack_join(status: "error", response: { "reason" => "denied" })
      join_rejoin_thread
      expect(rejoin_timer.tries).to eq(1)

      # The tick scheduled the rejoin, which sent a new phx_join — ack it OK
      # so the channel transitions to JOINED. That should reset the timer.
      ack_join(status: "ok", response: {})

      expect(channel).to be_joined
      expect(rejoin_timer.tries).to eq(0)
      expect(rejoin_timer.instance_variable_get(:@thread)).to be_nil
    end
  end

  describe "backoff curve" do
    it "uses the timer's current tries to compute each delay (2**tries capped at 60s)" do
      delays = []
      allow(rejoin_timer).to receive(:sleep) { |s| delays << s }

      channel.subscribe
      3.times do
        # Each call to on_join_error schedules another tick, advancing tries
        # by one after the sleep stub returns.
        channel.send(:on_join_error, { "reason" => "denied" })
        join_rejoin_thread
      end

      expect(delays).to eq([1.0, 2.0, 4.0])
    end
  end
end
