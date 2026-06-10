# frozen_string_literal: true

require "json"
require "supabase/realtime"

# Fake-socket harness for realtime wire-format specs (US-007..US-014). The class
# implements `Supabase::Realtime::Socket`, so it drops straight into
# `Supabase::Realtime::Client.new(socket: fake_realtime_socket)` and captures
# every frame the client emits as a parsed Hash — letting specs assert on the
# exact wire format without going through JSON unpacking.
#
#   socket  = fake_realtime_socket
#   client  = Supabase::Realtime::Client.new(url: "wss://x/v1", socket: socket)
#   client.connect
#   channel = client.channel("public:users")
#   channel.subscribe
#
#   expect(socket.sent_frames.last).to include(
#     "event" => "phx_join",
#     "topic" => "realtime:public:users"
#   )
#
#   socket.simulate_recv(
#     event: "phx_reply",
#     topic: "realtime:public:users",
#     payload: { "status" => "ok", "response" => {} },
#     ref: socket.sent_frames.last["ref"]
#   )
module RealtimeSocketHelper
  class FakeSocket
    include Supabase::Realtime::Socket

    # Every payload the client pushed, already JSON-parsed into a Hash. Specs
    # assert on this directly instead of round-tripping JSON in the example.
    attr_reader :sent_frames

    def initialize
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

    def send(payload)
      @sent_frames << JSON.parse(payload)
    end

    def connected?
      @connected
    end

    # Feed a frame as if it arrived from the server. Accepts a Hash (which gets
    # JSON-encoded for the client's on_message callback, mirroring the wire
    # format) or a raw JSON String for round-trip / parser-error specs.
    def simulate_recv(frame)
      raw = frame.is_a?(String) ? frame : JSON.generate(stringify_top_level(frame))
      message_callbacks.each { |cb| cb.call(raw) }
    end

    def last_sent_frame
      @sent_frames.last
    end

    def sent_events
      @sent_frames.map { |f| f["event"] }
    end

    def reset_sent_frames
      @sent_frames = []
    end

    private

    # Phoenix frames are wire-level JSON objects keyed by strings. Symbol keys in
    # specs are convenient — convert just the top level so `payload:` still gets
    # the caller's nested Hash verbatim.
    def stringify_top_level(hash)
      hash.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v }
    end
  end

  def fake_realtime_socket
    FakeSocket.new
  end
end

RSpec.configure do |config|
  config.include RealtimeSocketHelper
end
