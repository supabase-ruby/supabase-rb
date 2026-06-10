# frozen_string_literal: true

require "supabase/realtime"
require "json"

# US-017: A malformed WebSocket frame must NOT take down the read-loop.
# Previously `Message.parse` raised `ProtocolError`, which propagated into the
# socket adapter's `on_message` callback and killed the read thread on the very
# first garbled frame the server sent. After the fix `Message.parse` logs a
# warning and returns nil; `Client#handle_inbound` treats nil as "skip this
# frame" and keeps dispatching subsequent valid frames.
RSpec.describe "US-017: malformed frame is skipped, read-loop survives" do
  let(:socket) { Supabase::Realtime::TestSocket.new }
  let(:client) do
    Supabase::Realtime::Client.new(
      url: "wss://x/v1",
      socket: socket,
      heartbeat_interval: 0,
      auto_reconnect: false
    )
  end

  before { client.connect }

  it "logs a warning and returns nil instead of raising on bad JSON (AC #1)" do
    expect { @result = Supabase::Realtime::Message.parse("{not json") }
      .to output(/Skipping malformed Phoenix frame/).to_stderr
    expect(@result).to be_nil
  end

  it "does not raise when an invalid frame arrives on the wire (AC #2 — read-loop survives)" do
    expect { socket.inject("not a json frame") }
      .not_to raise_error
  end

  it "dispatches a valid frame that arrives AFTER a malformed one (AC #2 — subsequent frames still flow)" do
    channel = client.channel("public:users")
    channel.subscribe

    # Server sends a garbled frame first — the bug would kill the read thread here.
    expect { socket.inject("totally broken JSON {") }.not_to raise_error

    # ...then a valid phx_reply for the join. Must still reach the channel and
    # transition it to JOINED, proving the read-loop kept dispatching.
    join_ref = socket.last_sent_frame["ref"]
    socket.inject(
      "event"    => "phx_reply",
      "topic"    => "realtime:public:users",
      "payload"  => { "status" => "ok", "response" => { "fresh" => true } },
      "ref"      => join_ref,
      "join_ref" => join_ref
    )

    expect(channel.joined?).to be true
  end

  it "skips multiple malformed frames in a row without breaking dispatch" do
    channel = client.channel("public:users")
    channel.subscribe
    join_ref = socket.last_sent_frame["ref"]

    3.times { socket.inject("garbage #{rand}") }

    socket.inject(
      "event"    => "phx_reply",
      "topic"    => "realtime:public:users",
      "payload"  => { "status" => "ok", "response" => {} },
      "ref"      => join_ref,
      "join_ref" => join_ref
    )

    expect(channel.joined?).to be true
  end
end
