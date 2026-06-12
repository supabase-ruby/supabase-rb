# frozen_string_literal: true

require "supabase/realtime"
require "json"
require "logger"
require "stringio"

# US-003 / FR-4: After a background reconnect loop exhausts `max_retries`
# without re-establishing the socket, the user must be told. Mirrors
# `realtime/_async/client.py:141-193` where `connect()` raises on permanent
# failure. The rb port runs reconnect on a thread (no caller to raise to), so
# the same contract is delivered through `Client#on_reconnect_failed`.
#
# Q2 (explicit connect to an unavailable server) is settled by py-parity
# (D5 fix): `client.connect` retries synchronous transport failures with
# exponential backoff up to `max_retries`, then re-raises the last error —
# no silent success. With `auto_reconnect: false` the first failure raises
# immediately. See spec/supabase/realtime/connect_retry_spec.rb.
RSpec.describe "US-003: terminal reconnect failure is observable" do
  # TestSocket variant: fire_close pretends the server yanked the link, and
  # `make_connect_raise!` flips `connect` so every subsequent attempt fails
  # with the given exception — enough to drive the reconnect loop to
  # exhaustion deterministically.
  let(:flaky_socket) do
    Class.new(Supabase::Realtime::TestSocket) do
      def fire_close
        @connected = false
        close_callbacks.each(&:call)
      end

      def make_connect_raise!(err)
        @raise_on_connect = err
      end

      def connect
        if @raise_on_connect
          raise @raise_on_connect
        end

        super
      end
    end.new
  end

  describe "AC #1/#2 — on_reconnect_failed fires exactly once after max_retries" do
    it "delivers the last underlying error to the callback after N failed retries" do
      client = Supabase::Realtime::Client.new(
        url: "wss://x/v1",
        socket: flaky_socket,
        heartbeat_interval: 0,
        initial_backoff: 0.01,
        max_retries: 3
      )

      fired = Queue.new
      client.on_reconnect_failed { |err| fired << err }

      client.connect
      flaky_socket.make_connect_raise!(RuntimeError.new("server unreachable"))
      flaky_socket.fire_close

      err = fired.pop # would block forever and fail with Timeout if never delivered
      expect(err).to be_a(RuntimeError)
      expect(err.message).to eq("server unreachable")

      # Drain a brief grace window — if a second invocation slipped through it
      # would land here.
      sleep 0.1
      expect(fired.size).to eq(0)

      client.disconnect
    end

    it "does not fire when a reconnect attempt eventually succeeds" do
      client = Supabase::Realtime::Client.new(
        url: "wss://x/v1",
        socket: flaky_socket,
        heartbeat_interval: 0,
        initial_backoff: 0.01,
        max_retries: 3
      )

      fired_count = 0
      client.on_reconnect_failed { |_| fired_count += 1 }

      client.connect
      flaky_socket.fire_close # triggers schedule_reconnect, which will call socket.connect again
      sleep 0.2 # let the backoff/connect cycle land
      expect(client).to be_connected
      expect(fired_count).to eq(0)

      client.disconnect
    end

    it "does not fire when disconnect() interrupts the reconnect loop" do
      client = Supabase::Realtime::Client.new(
        url: "wss://x/v1",
        socket: flaky_socket,
        heartbeat_interval: 0,
        initial_backoff: 0.05,
        max_retries: 5
      )

      fired_count = 0
      client.on_reconnect_failed { |_| fired_count += 1 }

      client.connect
      flaky_socket.make_connect_raise!(RuntimeError.new("server unreachable"))
      flaky_socket.fire_close
      sleep 0.02 # mid-backoff
      client.disconnect
      sleep 0.3 # the loop would otherwise burn through all 5 retries here

      expect(fired_count).to eq(0)
    end
  end

  describe "AC #3/#5 — explicit connect to unavailable server propagates immediately (Q2: py-parity)" do
    it "raises the transport error from client.connect when the socket cannot open" do
      flaky_socket.make_connect_raise!(RuntimeError.new("ECONNREFUSED"))

      client = Supabase::Realtime::Client.new(
        url: "wss://x/v1",
        socket: flaky_socket,
        heartbeat_interval: 0,
        initial_backoff: 0.01,
        max_retries: 3,
        auto_reconnect: false
      )

      expect { client.connect }.to raise_error(RuntimeError, "ECONNREFUSED")
      expect(client).not_to be_connected
    end

    it "does not fire on_reconnect_failed when the explicit connect raises" do
      flaky_socket.make_connect_raise!(RuntimeError.new("ECONNREFUSED"))

      client = Supabase::Realtime::Client.new(
        url: "wss://x/v1",
        socket: flaky_socket,
        heartbeat_interval: 0,
        initial_backoff: 0.01,
        max_retries: 3
      )

      fired = 0
      client.on_reconnect_failed { |_| fired += 1 }

      expect { client.connect }.to raise_error("ECONNREFUSED")
      sleep 0.2
      expect(fired).to eq(0)
    end
  end

  describe "multiple registrations + safety" do
    it "invokes every registered callback in registration order" do
      client = Supabase::Realtime::Client.new(
        url: "wss://x/v1",
        socket: flaky_socket,
        heartbeat_interval: 0,
        initial_backoff: 0.01,
        max_retries: 2
      )

      order = Queue.new
      client.on_reconnect_failed { |_| order << :a }
      client.on_reconnect_failed { |_| order << :b }

      client.connect
      flaky_socket.make_connect_raise!(RuntimeError.new("nope"))
      flaky_socket.fire_close

      first  = order.pop
      second = order.pop
      expect([first, second]).to eq([:a, :b])

      client.disconnect
    end

    it "a raise inside one on_reconnect_failed block does not block the next" do
      log_buffer = StringIO.new
      logger     = Logger.new(log_buffer).tap { |l| l.level = Logger::WARN }
      client = Supabase::Realtime::Client.new(
        url: "wss://x/v1",
        socket: flaky_socket,
        heartbeat_interval: 0,
        initial_backoff: 0.01,
        max_retries: 2,
        logger: logger
      )

      second_fired = Queue.new
      client.on_reconnect_failed { |_| raise "user code bug" }
      client.on_reconnect_failed { |_| second_fired << :ok }

      client.connect
      flaky_socket.make_connect_raise!(RuntimeError.new("nope"))
      flaky_socket.fire_close

      expect(second_fired.pop).to eq(:ok)
      expect(log_buffer.string).to include("reconnect_failed")
      expect(log_buffer.string).to include("user code bug")

      client.disconnect
    end
  end
end
