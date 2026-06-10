# frozen_string_literal: true

require "supabase/realtime"
require "json"

# US-016: After `unsubscribe`, an automatic reconnect must NOT re-join the
# channel. Previously `Client#rejoin_channels` walked every channel whose
# `@joined_once` flag was true and skipped only those already JOINING, which
# silently revived an explicitly torn-down subscription on the next reconnect.
#
# Fix: filter by lifecycle state — only JOINED (live subscription that the
# socket close interrupted) or JOINING (handshake in flight) channels are
# re-joined. LEAVING / CLOSED / ERRORED stay quiet.
RSpec.describe "US-016: unsubscribe before reconnect blocks rejoin" do
  let(:reconnect_socket) do
    Class.new(Supabase::Realtime::TestSocket) do
      def initialize
        super
        @connect_count = 0
      end

      attr_reader :connect_count

      def connect
        @connect_count += 1
        super
      end

      def fire_close
        @connected = false
        close_callbacks.each(&:call)
      end
    end.new
  end

  let(:client) do
    Supabase::Realtime::Client.new(
      url: "wss://x/v1",
      socket: reconnect_socket,
      heartbeat_interval: 0,
      initial_backoff: 0.02,
      max_retries: 3
    )
  end

  def ack_last_push(channel)
    ref = reconnect_socket.last_sent_frame["ref"]
    reconnect_socket.inject(
      "event"    => "phx_reply",
      "topic"    => channel.topic,
      "payload"  => { "status" => "ok", "response" => {} },
      "ref"      => ref,
      "join_ref" => ref
    )
  end

  it "does not send phx_join for a channel that called unsubscribe (LEAVING, no leave-ack)" do
    client.connect
    channel = client.channel("realtime:public:posts")
    channel.subscribe
    ack_last_push(channel)
    expect(channel).to be_joined

    # Caller tears the subscription down. Without a leave-ack the channel
    # stays in LEAVING.
    channel.unsubscribe
    expect(channel).to be_leaving

    reconnect_socket.reset_sent_frames
    reconnect_socket.fire_close
    sleep 0.08

    join_frames = reconnect_socket.sent_frames
                                  .map { |f| JSON.parse(f) }
                                  .select { |f| f["event"] == "phx_join" && f["topic"] == channel.topic }
    expect(join_frames).to be_empty
    expect(channel).to be_leaving
    client.disconnect
  end

  it "does not send phx_join for a channel whose leave was acked (CLOSED)" do
    client.connect
    channel = client.channel("realtime:public:items")
    channel.subscribe
    ack_last_push(channel)
    expect(channel).to be_joined

    channel.unsubscribe
    ack_last_push(channel) # leave-ack → state goes to CLOSED
    expect(channel).to be_closed

    reconnect_socket.reset_sent_frames
    reconnect_socket.fire_close
    sleep 0.08

    join_frames = reconnect_socket.sent_frames
                                  .map { |f| JSON.parse(f) }
                                  .select { |f| f["event"] == "phx_join" && f["topic"] == channel.topic }
    expect(join_frames).to be_empty
    expect(channel).to be_closed
    client.disconnect
  end

  it "still rejoins channels that were JOINED at the time the socket dropped" do
    client.connect
    live    = client.channel("realtime:public:live")
    torn    = client.channel("realtime:public:torn")
    live.subscribe
    ack_last_push(live)
    torn.subscribe
    ack_last_push(torn)
    torn.unsubscribe

    reconnect_socket.reset_sent_frames
    reconnect_socket.fire_close
    sleep 0.08

    join_frames = reconnect_socket.sent_frames.map { |f| JSON.parse(f) }
    expect(join_frames.any? { |f| f["event"] == "phx_join" && f["topic"] == live.topic }).to be(true)
    expect(join_frames.none? { |f| f["event"] == "phx_join" && f["topic"] == torn.topic }).to be(true)
    client.disconnect
  end
end
