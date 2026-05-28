# frozen_string_literal: true

require "supabase/realtime"
require "json"

RSpec.describe Supabase::Realtime::TestSocket do
  let(:socket) { described_class.new }

  it "tracks the connected? flag through connect/close" do
    expect(socket.connected?).to be false
    socket.connect
    expect(socket.connected?).to be true
    socket.close
    expect(socket.connected?).to be false
  end

  it "fires on_open / on_close callbacks during lifecycle transitions" do
    opened = closed = false
    socket.on_open  { opened = true }
    socket.on_close { closed = true }

    socket.connect
    socket.close
    expect(opened).to be true
    expect(closed).to be true
  end

  describe "frame capture / injection (the parts that make tests possible)" do
    it "captures every sent payload in sent_frames" do
      socket.send("a")
      socket.send("b")
      expect(socket.sent_frames).to eq(%w[a b])
    end

    it "exposes the most recent frame already JSON-parsed" do
      socket.send(JSON.generate("x" => 1))
      expect(socket.last_sent_frame).to eq("x" => 1)
    end

    it "returns nil for last_sent_frame when nothing has been sent yet" do
      expect(socket.last_sent_frame).to be_nil
    end

    it "lists the events of every sent frame for quick assertions" do
      socket.send(JSON.generate("event" => "phx_join"))
      socket.send(JSON.generate("event" => "heartbeat"))
      expect(socket.sent_events).to eq(%w[phx_join heartbeat])
    end

    it "lets reset_sent_frames clear the capture buffer for new assertions" do
      socket.send("a")
      socket.reset_sent_frames
      expect(socket.sent_frames).to be_empty
    end

    it "accepts both raw JSON strings and Hashes through #inject" do
      received = []
      socket.on_message { |raw| received << raw }

      socket.inject("event" => "x", "topic" => "t")
      socket.inject(JSON.generate("event" => "y", "topic" => "t"))

      parsed = received.map { |r| JSON.parse(r)["event"] }
      expect(parsed).to contain_exactly("x", "y")
    end
  end

  it "raises NotImplementedError if you call Socket's interface methods on a bare include" do
    klass = Class.new { include Supabase::Realtime::Socket }
    bare  = klass.new
    expect { bare.connect }.to raise_error(NotImplementedError)
    expect { bare.close }.to raise_error(NotImplementedError)
    expect { bare.send("x") }.to raise_error(NotImplementedError)
    expect { bare.connected? }.to raise_error(NotImplementedError)
  end
end
