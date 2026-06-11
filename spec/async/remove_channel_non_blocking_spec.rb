# frozen_string_literal: true

require "async"
require "supabase"
require "supabase/realtime"

# US-050 — `Supabase::Client#remove_channel` / `#remove_all_channels` under
# `async: true`.
#
# supabase-py's AsyncClient exposes these as `async def` (supabase/_async/
# client.py:231-237), so Python callers `await` the teardown. The Ruby
# realtime client is thread-based and its `unsubscribe` ends in a blocking
# `Socket#send` (the phx_leave frame). Without dispatch, that write would
# stall the calling fiber for the full send duration — the same failure mode
# US-047 measured for `apply_auth`.
#
# Contract under test (mirrors US-047/US-048's apply_auth fix):
#   * async mode: the call returns in < WRITE_DELAY (dispatched as a child
#     Async task) and returns an `Async::Task` the caller can `.wait` on —
#     the Ruby spelling of Python's `await client.remove_channel(ch)`.
#   * the phx_leave frame still reaches the socket by the time the reactor
#     drains.
#   * sync mode: unchanged — calls through and returns the realtime client's
#     plain return value, no Async involved.
class SlowLeaveTestSocket
  include Supabase::Realtime::Socket

  attr_reader :sent_frames, :write_delay

  def initialize(write_delay:)
    @write_delay = write_delay
    @connected   = false
    @sent_frames = []
  end

  def connect
    @connected = true
    open_callbacks.each(&:call)
  end

  def close
    @connected = false
    close_callbacks.each(&:call)
  end

  def connected?
    @connected
  end

  def send(payload)
    sleep @write_delay
    @sent_frames << payload
  end
end

RSpec.describe "US-050 — Supabase::Client#remove_channel under async: true" do
  WRITE_DELAY = 0.2

  def build_client_with_slow_realtime(async:)
    client = Supabase::Client.new(
      supabase_url: "https://abc.supabase.co",
      supabase_key: "anon-key",
      async:        async
    )

    slow_socket = SlowLeaveTestSocket.new(write_delay: WRITE_DELAY)
    realtime = Supabase::Realtime::Client.new(
      url:                "wss://abc.supabase.co/realtime/v1",
      params:             {},
      transport:          slow_socket,
      heartbeat_interval: 0,
      auto_reconnect:     false
    )
    realtime.connect
    client.instance_variable_set(:@realtime, realtime)

    [client, realtime, slow_socket]
  end

  def joined_channel(realtime, slow_socket, topic)
    channel = realtime.channel(topic)
    channel.instance_variable_set(:@state, Supabase::Realtime::Types::ChannelStates::JOINED)
    slow_socket.sent_frames.clear
    channel
  end

  it "returns to the calling fiber before the phx_leave write drains, and is awaitable" do
    client, realtime, slow_socket = build_client_with_slow_realtime(async: true)
    channel = joined_channel(realtime, slow_socket, "realtime:public:users")

    duration = nil
    returned = nil

    Async do
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      returned = client.remove_channel(channel)
      duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

      # Python parity: `await client.remove_channel(ch)` ⇔ `.wait` on the task.
      returned.wait
    end

    expect(duration).to be < WRITE_DELAY
    expect(returned).to respond_to(:wait)

    # After the reactor drains, the leave frame reached the socket and the
    # channel left the registry.
    leave_frame = slow_socket.sent_frames.find { |f| f.include?("phx_leave") }
    expect(leave_frame).not_to be_nil
    expect(realtime.get_channels).not_to include(channel)
  end

  it "remove_all_channels dispatches the same way and empties the registry" do
    client, realtime, slow_socket = build_client_with_slow_realtime(async: true)
    joined_channel(realtime, slow_socket, "realtime:public:a")
    channel_b = realtime.channel("realtime:public:b")
    channel_b.instance_variable_set(:@state, Supabase::Realtime::Types::ChannelStates::JOINED)
    slow_socket.sent_frames.clear

    duration = nil

    Async do
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      client.remove_all_channels.wait
      duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    end

    # Two slow leave-writes ran inside the child task; the dispatch call
    # itself (measured up to `.wait`) proves the frames were written by the
    # time the task resolves.
    expect(duration).to be >= WRITE_DELAY
    expect(slow_socket.sent_frames.count { |f| f.include?("phx_leave") }).to eq(2)
    expect(realtime.get_channels).to be_empty
  end

  it "sync mode calls straight through without Async" do
    client, realtime, slow_socket = build_client_with_slow_realtime(async: false)
    channel = joined_channel(realtime, slow_socket, "realtime:public:users")

    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    client.remove_channel(channel)
    duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

    # Blocking semantics preserved: the call waited out the slow write inline.
    expect(duration).to be >= WRITE_DELAY
    expect(slow_socket.sent_frames.find { |f| f.include?("phx_leave") }).not_to be_nil
    expect(realtime.get_channels).not_to include(channel)
  end
end
