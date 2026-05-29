# frozen_string_literal: true

require "async"
require "protocol/websocket/message"

require "supabase/realtime"
require "supabase/realtime/sockets/async_websocket"

# In-memory stand-in for an Async::WebSocket::Connection. Driven entirely
# through an Async::Queue so specs can push frames into the read loop
# cooperatively (no threads, no real sockets).
class FakeAsyncConnection
  attr_reader :written, :closed

  def initialize
    @incoming = Async::Queue.new
    @written  = []
    @closed   = false
  end

  def read
    @incoming.dequeue
  end

  def write(message)
    @written << message
  end

  def flush; end

  def close
    @closed = true
    @incoming.enqueue(nil) # break the read loop
  end

  # ---- Driver helpers used by specs ----

  def simulate_text(payload)
    @incoming.enqueue(::Protocol::WebSocket::TextMessage.new(payload))
  end

  def simulate_binary(bytes)
    @incoming.enqueue(::Protocol::WebSocket::BinaryMessage.new(bytes))
  end

  def simulate_eof
    @incoming.enqueue(nil)
  end
end

# Drop-in for Async::WebSocket::Client — captures arguments and yields a
# FakeAsyncConnection synchronously so the adapter's session task gets a
# live (fake) connection without any real I/O.
class FakeAsyncConnector
  attr_reader :last_endpoint, :last_headers, :connection

  def initialize
    @connection = FakeAsyncConnection.new
  end

  def connect(endpoint, headers: nil, **)
    @last_endpoint = endpoint
    @last_headers  = headers
    yield @connection
  ensure
    @connection.close unless @connection.closed
  end
end

RSpec.describe Supabase::Realtime::Sockets::AsyncWebsocket do
  let(:connector) { FakeAsyncConnector.new }
  let(:url)       { "wss://example.com/realtime/v1/websocket?vsn=1.0.0" }

  def build_socket(headers: { "X-Custom" => "h" })
    described_class.new(url: url, headers: headers, connector: connector)
  end

  describe "type tree" do
    it "satisfies the Supabase::Realtime::Socket contract" do
      expect(described_class.ancestors).to include(Supabase::Realtime::Socket)
    end
  end

  describe "#connect" do
    it "must run inside an Async block" do
      socket = build_socket
      expect { socket.connect }.to raise_error(Supabase::Realtime::Errors::RealtimeError, /Async/)
    end

    it "parses the URL into an HTTP endpoint and forwards headers as pairs" do
      Sync do
        socket = build_socket
        socket.connect

        expect(connector.last_endpoint).to be_a(Async::HTTP::Endpoint)
        expect(connector.last_endpoint.to_url.to_s).to include("example.com")
        expect(connector.last_headers).to eq([["X-Custom", "h"]])

        socket.close
      end
    end

    it "fires on_open exactly once before #connect returns to the caller" do
      Sync do
        socket = build_socket
        opens  = []
        socket.on_open { opens << :open }

        socket.connect

        expect(opens).to eq([:open])
        expect(socket).to be_connected

        socket.close
      end
    end

    it "is a no-op the second time (so reconnect logic in callers stays simple)" do
      Sync do
        socket = build_socket
        socket.connect
        first  = connector.connection

        socket.connect # no-op while already connected

        expect(connector.connection).to be(first)
        socket.close
      end
    end
  end

  describe "message dispatch" do
    it "forwards text frames to every on_message listener" do
      Sync do |task|
        socket = build_socket
        seen   = []
        socket.on_message { |m| seen << m }
        socket.connect

        connector.connection.simulate_text(%({"event":"phx_reply"}))
        task.yield # let the read loop process

        expect(seen).to eq([%({"event":"phx_reply"})])
        socket.close
      end
    end

    it "drops binary frames (Phoenix protocol is text-only)" do
      Sync do |task|
        socket = build_socket
        seen   = []
        socket.on_message { |m| seen << m }
        socket.connect

        connector.connection.simulate_binary("ignored")
        task.yield

        expect(seen).to be_empty
        socket.close
      end
    end
  end

  describe "#send" do
    it "writes payloads as text frames to the underlying connection" do
      Sync do
        socket = build_socket
        socket.connect

        socket.send(%({"event":"heartbeat"}))

        expect(connector.connection.written).to eq([%({"event":"heartbeat"})])

        socket.close
      end
    end

    it "is a no-op when not connected (defensive — race-free shutdown)" do
      socket = build_socket
      expect { socket.send("x") }.not_to raise_error
    end
  end

  describe "#close" do
    it "tears the session down and clears connected?" do
      Sync do |task|
        socket = build_socket
        closes = []
        socket.on_close { closes << :closed }
        socket.connect

        socket.close
        task.yield # let the session task observe the stop

        expect(socket.connected?).to be false
        expect(closes).to eq([:closed])
      end
    end

    it "is a no-op when never connected" do
      expect { build_socket.close }.not_to raise_error
    end
  end

  describe "error fan-out" do
    it "forwards exceptions from the read loop to on_error and ends the session" do
      Sync do |task|
        # Make read raise the second time it's called: first returns the
        # text frame, second blows up. The adapter must surface that to
        # on_error rather than crashing the session task silently.
        boom = StandardError.new("read failed")
        allow(connector.connection).to receive(:read).and_wrap_original do |orig, *args|
          @reads ||= 0
          @reads += 1
          @reads == 1 ? orig.call(*args) : (raise boom)
        end

        socket = build_socket
        errors = []
        socket.on_error { |e| errors << e }
        socket.connect

        connector.connection.simulate_text(%({"event":"phx_reply"}))
        task.yield
        task.yield # let the second read raise

        expect(errors).to include(boom)
        socket.close
      end
    end
  end

  describe "end-to-end through Realtime::Client" do
    it "delivers a server frame all the way through to a channel listener" do
      Sync do |task|
        socket = build_socket
        client = Supabase::Realtime::Client.new(url: url, socket: socket)
        client.connect

        channel    = client.channel("realtime:public:users")
        seen_state = nil
        channel.subscribe { |state, _err| seen_state = state }

        # Capture the phx_join the client just pushed so we can reply to it.
        join_frame = JSON.parse(connector.connection.written.last)
        connector.connection.simulate_text(JSON.generate(
          "event"    => "phx_reply",
          "topic"    => channel.topic,
          "payload"  => { "status" => "ok", "response" => {} },
          "ref"      => join_frame["ref"],
          "join_ref" => join_frame["ref"]
        ))
        task.yield

        expect(channel).to be_joined
        expect(seen_state).to eq("SUBSCRIBED")

        socket.close
      end
    end
  end
end
