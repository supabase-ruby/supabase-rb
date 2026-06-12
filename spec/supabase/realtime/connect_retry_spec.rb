# frozen_string_literal: true

require "supabase/realtime"

# D5 — initial-connect retry/backoff parity with supabase-py.
#
# py `connect()` (realtime/_async/client.py:141-193) retries a failing
# connection attempt with exponential backoff (`initial_backoff * 2^(n-1)`)
# for up to `max_retries` total attempts, then re-raises the last transport
# error; with `auto_reconnect=False` the first failure raises immediately.
# Before this fix the rb port made exactly one `Socket#connect` attempt and
# propagated the error, and a synchronous raise also left the `@connecting`
# guard stuck at `true`, so every later `connect` call short-circuited into
# a silent no-op.
RSpec.describe "Realtime D5: connect retries with backoff" do
  let(:flaky_socket) do
    Class.new(Supabase::Realtime::TestSocket) do
      attr_reader :attempts
      attr_writer :failures_left

      def connect
        @attempts = (@attempts || 0) + 1
        @failures_left ||= 0
        if @failures_left.positive?
          @failures_left -= 1
          raise "ECONNREFUSED"
        end

        super
      end
    end.new
  end

  def build_client(socket, **opts)
    Supabase::Realtime::Client.new(
      url: "wss://x/v1", socket: socket, heartbeat_interval: 0,
      initial_backoff: 0.01, max_retries: 3, **opts
    )
  end

  it "retries a failing connect and succeeds when a later attempt connects" do
    flaky_socket.failures_left = 2
    client = build_client(flaky_socket)

    expect { client.connect }.not_to raise_error
    expect(client).to be_connected
    expect(flaky_socket.attempts).to eq(3)

    client.disconnect
  end

  it "re-raises the last error after max_retries attempts are exhausted" do
    flaky_socket.failures_left = 10
    client = build_client(flaky_socket)

    expect { client.connect }.to raise_error(RuntimeError, "ECONNREFUSED")
    expect(flaky_socket.attempts).to eq(3)
    expect(client).not_to be_connected
  end

  it "sleeps the py backoff curve (initial * 2^(n-1)) between attempts" do
    flaky_socket.failures_left = 10
    client = build_client(flaky_socket, initial_backoff: 1.0, max_retries: 4)

    delays = []
    allow(client).to receive(:sleep) { |d| delays << d }

    expect { client.connect }.to raise_error("ECONNREFUSED")
    # 4 attempts → 3 waits: 1.0, 2.0, 4.0 (no sleep after the final failure).
    expect(delays).to eq([1.0, 2.0, 4.0])
  end

  it "raises on the first failure when auto_reconnect is false (py parity)" do
    flaky_socket.failures_left = 10
    client = build_client(flaky_socket, auto_reconnect: false)

    expect { client.connect }.to raise_error("ECONNREFUSED")
    expect(flaky_socket.attempts).to eq(1)
  end

  it "a failed connect does not leave the @connecting guard stuck (regression)" do
    flaky_socket.failures_left = 1
    client = build_client(flaky_socket, auto_reconnect: false)

    expect { client.connect }.to raise_error("ECONNREFUSED")

    # The transport recovered; a fresh connect must actually try again
    # instead of short-circuiting on a stale "in flight" flag.
    expect { client.connect }.not_to raise_error
    expect(client).to be_connected

    client.disconnect
  end

  it "a concurrent disconnect aborts the retry loop quietly" do
    flaky_socket.failures_left = 10
    client = build_client(flaky_socket, initial_backoff: 0.05, max_retries: 5)

    connect_result = Queue.new
    t = Thread.new do
      connect_result << begin
        client.connect
        :returned
      rescue StandardError => e
        e
      end
    end

    sleep 0.02 # land inside the first backoff window
    client.disconnect
    result = connect_result.pop

    expect(result).to eq(:returned)
    expect(flaky_socket.attempts).to be < 5
    t.join
  end
end
