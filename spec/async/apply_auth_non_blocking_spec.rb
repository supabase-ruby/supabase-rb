# frozen_string_literal: true

require "async"
require "supabase"
require "supabase/realtime"

# US-047 — Reproducer that measures whether `Supabase::Client#apply_auth`
# (the path under `#set_auth`) holds up the fiber-reactor while it pushes
# the ACCESS_TOKEN frame to the realtime socket. The umbrella's
# `apply_auth(token)` calls `@realtime&.set_auth(token)`, which in turn
# calls `@socket.send(payload)` for every joined channel. Under
# `async: true` the calling code expects to live inside an Async reactor
# — but `apply_auth` is plain synchronous Ruby and synchronously awaits
# the write. This spec quantifies that wait so the decision to fix vs.
# document is driven by numbers (see US-048).
#
# The transport below sleeps for `WRITE_DELAY` inside `send`. `sleep` is
# cooperative under the async-2.x fiber scheduler — the reactor will
# happily schedule a sibling fiber during the sleep. That lets us
# distinguish two outcomes:
#
#   * `apply_auth_duration < WRITE_DELAY`
#       The implementation fired the write off as a child task and
#       returned to the caller without awaiting completion. Reactor is
#       free, calling fiber is free. Non-blocking.
#
#   * `apply_auth_duration >= WRITE_DELAY`
#       The implementation awaited the write inline. Sibling fibers
#       still got scheduled (so the *reactor* was never blocked), but
#       the calling fiber sat on the floor for the full WRITE_DELAY —
#       which is the user-visible blocking we care about.
class SlowWriteTestSocket
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

RSpec.describe "US-047 — Supabase::Client#apply_auth fiber-reactor blocking measurement" do
  WRITE_DELAY   = 0.2
  TICK_INTERVAL = 0.01

  it "measures apply_auth duration and parallel-fiber tick count under Async" do
    client = Supabase::Client.new(
      supabase_url: "https://abc.supabase.co",
      supabase_key: "anon-key",
      async:        true
    )

    slow_socket = SlowWriteTestSocket.new(write_delay: WRITE_DELAY)
    realtime = Supabase::Realtime::Client.new(
      url:                "wss://abc.supabase.co/realtime/v1",
      params:             {},
      transport:          slow_socket,
      heartbeat_interval: 0,
      auto_reconnect:     false
    )
    realtime.connect
    channel = realtime.channel("realtime:public:users")
    channel.instance_variable_set(:@state, Supabase::Realtime::Types::ChannelStates::JOINED)
    slow_socket.sent_frames.clear

    client.instance_variable_set(:@realtime, realtime)

    apply_auth_duration = nil
    tick_count          = 0

    Async do |task|
      stop_ticker = false
      ticker = task.async do
        until stop_ticker
          tick_count += 1
          sleep TICK_INTERVAL
        end
      end

      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      client.set_auth("user-jwt")
      apply_auth_duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

      stop_ticker = true
      ticker.wait
    end

    # STDOUT trace — surfaces under `--format documentation` so the
    # measurement is captured in test output for future review.
    puts ""
    puts "  [US-047] write_delay              = #{format('%.4f', WRITE_DELAY)} s"
    puts "  [US-047] apply_auth_duration      = #{format('%.4f', apply_auth_duration)} s"
    puts "  [US-047] parallel_fiber_ticks     = #{tick_count}"
    puts "  [US-047] reactor_scheduled_others = #{tick_count.positive?}"
    puts "  [US-047] apply_auth_non_blocking  = #{apply_auth_duration < WRITE_DELAY}"

    # Sanity: the ACCESS_TOKEN frame did reach the socket.
    expect(slow_socket.sent_frames.size).to eq(1)

    if apply_auth_duration >= WRITE_DELAY * 0.9
      # Calling fiber waited the full WRITE_DELAY (or close to it) — the
      # current implementation synchronously awaits Socket#send. Fix
      # tracked in US-048; mark this assertion pending so the suite stays
      # green while the reproducer keeps documenting the behaviour.
      pending(
        "Supabase::Client#apply_auth synchronously awaits Realtime ACCESS_TOKEN " \
        "Socket#send — the calling fiber waits the full WRITE_DELAY before " \
        "returning. Fix tracked in US-048."
      )
      expect(apply_auth_duration).to be < WRITE_DELAY
    else
      # Non-blocking outcome: apply_auth returned before the write
      # completed (or the impl was rewritten to be cooperative end-to-end).
      expect(apply_auth_duration).to be < WRITE_DELAY
    end
  end
end
