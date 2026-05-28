# frozen_string_literal: true

require "supabase/realtime"
require "supabase/realtime/sockets/websocket_client_simple"

# Fakes mimicking websocket-client-simple's surface so we never open a TCP
# socket from the spec process. The real gem yields a Client to the
# `connect(url, &block)` block, then runs the read loop on a background thread.
# Our fake skips the thread and exposes simulate_* helpers so tests drive the
# event stream synchronously.
class FakeWebSocketClient
  attr_accessor :sent, :open_handlers, :message_handlers, :close_handlers, :error_handlers
  attr_accessor :open, :closed

  def initialize
    @open = false
    @closed = false
    @sent = []
    @open_handlers = []
    @message_handlers = []
    @close_handlers = []
    @error_handlers = []
  end

  def on(event, &blk)
    case event
    when :open    then @open_handlers    << blk
    when :message then @message_handlers << blk
    when :close   then @close_handlers   << blk
    when :error   then @error_handlers   << blk
    end
  end

  def send(payload)
    @sent << payload
  end

  def close
    @closed = true
    @open = false
  end

  def open?
    @open
  end

  # ---- Driver helpers used by specs ----
  def simulate_open
    @open = true
    @open_handlers.each(&:call)
  end

  def simulate_message(data, type: :text)
    msg = Struct.new(:data, :type).new(data, type)
    @message_handlers.each { |h| h.call(msg) }
  end

  def simulate_close(reason = nil)
    @open = false
    @closed = true
    @close_handlers.each { |h| h.call(reason) }
  end

  def simulate_error(err)
    @error_handlers.each { |h| h.call(err) }
  end
end

class FakeConnector
  attr_reader :last_url, :last_options, :ws

  def connect(url, options = {})
    @last_url = url
    @last_options = options
    @ws = FakeWebSocketClient.new
    yield @ws if block_given?
    @ws
  end
end

RSpec.describe Supabase::Realtime::Sockets::WebsocketClientSimple do
  let(:connector) { FakeConnector.new }
  let(:url)       { "wss://example.com/realtime/v1/websocket?vsn=1.0.0" }
  let(:socket)    { described_class.new(url: url, headers: { "X-Custom" => "h" }, connector: connector) }

  describe "type tree" do
    it "satisfies the Supabase::Realtime::Socket contract" do
      expect(described_class.ancestors).to include(Supabase::Realtime::Socket)
    end
  end

  describe "#connect" do
    it "calls the connector with the URL and headers, then wires the WS event handlers" do
      socket.connect

      expect(connector.last_url).to eq(url)
      expect(connector.last_options).to eq(headers: { "X-Custom" => "h" })
      # All four lifecycle events should have been bound on the WS client.
      expect(connector.ws.open_handlers.length).to eq(1)
      expect(connector.ws.message_handlers.length).to eq(1)
      expect(connector.ws.close_handlers.length).to eq(1)
      expect(connector.ws.error_handlers.length).to eq(1)
    end

    it "is a no-op the second time (so reconnect logic in callers stays simple)" do
      socket.connect
      ws_before = connector.ws
      connector.ws.simulate_open
      socket.connect # no-op
      expect(connector.ws).to be(ws_before)
    end
  end

  describe "lifecycle callback fan-out" do
    before do
      socket.connect
      @opens = []; @messages = []; @closes = []; @errors = []
      socket.on_open    { @opens << true }
      socket.on_message { |m| @messages << m }
      socket.on_close   { @closes << true }
      socket.on_error   { |e| @errors << e }
    end

    it "forwards :open to every on_open listener" do
      connector.ws.simulate_open
      expect(@opens).to eq([true])
    end

    it "forwards :message text frames to every on_message listener" do
      connector.ws.simulate_open
      connector.ws.simulate_message(%({"event":"phx_reply"}))
      expect(@messages).to eq([%({"event":"phx_reply"})])
    end

    it "drops non-text frames (Phoenix uses only text — binary pings shouldn't reach the dispatcher)" do
      connector.ws.simulate_open
      connector.ws.simulate_message("binary-bytes", type: :binary)
      expect(@messages).to be_empty
    end

    it "forwards :close to every on_close listener and marks the socket disconnected" do
      connector.ws.simulate_open
      connector.ws.simulate_close
      expect(@closes).to eq([true])
      expect(socket.connected?).to be false
    end

    it "forwards :error to every on_error listener" do
      err = StandardError.new("oops")
      connector.ws.simulate_open
      connector.ws.simulate_error(err)
      expect(@errors).to eq([err])
    end
  end

  describe "#send / #connected? / #close" do
    before { socket.connect }

    it "tracks connected? from the WS client's open? flag" do
      expect(socket.connected?).to be false
      connector.ws.simulate_open
      expect(socket.connected?).to be true
    end

    it "forwards #send to the underlying WS" do
      connector.ws.simulate_open
      socket.send(%({"event":"heartbeat"}))
      expect(connector.ws.sent).to eq([%({"event":"heartbeat"})])
    end

    it "#close tears down the WS and clears the connected? flag" do
      connector.ws.simulate_open
      socket.close
      expect(socket.connected?).to be false
    end

    it "send/close are no-ops when not yet connected (defensive — race-free shutdown)" do
      fresh = described_class.new(url: url, connector: FakeConnector.new)
      expect { fresh.send("x") }.not_to raise_error
      expect { fresh.close }.not_to raise_error
    end
  end

  describe "end-to-end through Realtime::Client" do
    let(:client) { Supabase::Realtime::Client.new(url: url, socket: socket) }

    it "delivers a server frame all the way through to a channel listener" do
      client.connect
      connector.ws.simulate_open

      channel = client.channel("realtime:public:users")
      seen_state = nil
      channel.subscribe { |state, _err| seen_state = state }

      # The client pushed phx_join — capture its ref so we can fabricate the reply.
      join_frame = JSON.parse(connector.ws.sent.last)
      connector.ws.simulate_message(JSON.generate(
        "event"    => "phx_reply",
        "topic"    => channel.topic,
        "payload"  => { "status" => "ok", "response" => {} },
        "ref"      => join_frame["ref"],
        "join_ref" => join_frame["ref"]
      ))

      expect(channel).to be_joined
      expect(seen_state).to eq("SUBSCRIBED")
    end

    it "routes a postgres_changes frame to the matching channel listener" do
      client.connect
      connector.ws.simulate_open

      channel = client.channel("realtime:public:users")
      received = nil
      channel.on_postgres_changes("INSERT", schema: "public", table: "users") { |p| received = p }
      channel.subscribe

      # Ack the join so the channel transitions to JOINED.
      join_frame = JSON.parse(connector.ws.sent.last)
      connector.ws.simulate_message(JSON.generate(
        "event"   => "phx_reply", "topic" => channel.topic,
        "payload" => { "status" => "ok", "response" => {} },
        "ref"     => join_frame["ref"]
      ))

      connector.ws.simulate_message(JSON.generate(
        "event"   => "postgres_changes",
        "topic"   => channel.topic,
        "payload" => { "data" => { "type" => "INSERT", "schema" => "public", "table" => "users",
                                   "record" => { "id" => 1 } }, "ids" => [1] }
      ))

      expect(received["data"]["type"]).to eq("INSERT")
    end
  end
end
