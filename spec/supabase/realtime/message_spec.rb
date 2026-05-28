# frozen_string_literal: true

require "supabase/realtime"
require "json"

RSpec.describe Supabase::Realtime::Message do
  describe ".parse" do
    it "decodes a Phoenix frame into a struct with event/topic/payload/ref/join_ref" do
      raw = JSON.generate(
        "event" => "phx_reply", "topic" => "realtime:public:users",
        "payload" => { "status" => "ok", "response" => {} },
        "ref" => "1", "join_ref" => "1"
      )
      msg = described_class.parse(raw)

      expect(msg.event).to eq("phx_reply")
      expect(msg.topic).to eq("realtime:public:users")
      expect(msg.payload).to eq("status" => "ok", "response" => {})
      expect(msg.ref).to eq("1")
      expect(msg.join_ref).to eq("1")
    end

    it "defaults a missing payload to an empty hash so dispatch doesn't NPE" do
      raw = JSON.generate("event" => "phx_close", "topic" => "t")
      expect(described_class.parse(raw).payload).to eq({})
    end

    it "raises ProtocolError on malformed JSON (rescue point for socket adapters)" do
      expect { described_class.parse("not json") }
        .to raise_error(Supabase::Realtime::Errors::ProtocolError, /Malformed/)
    end
  end

  describe "#to_json" do
    it "serializes back into the wire format Phoenix expects" do
      msg = described_class.new(
        event: "phx_join", topic: "realtime:public:users",
        payload: { "config" => {} }, ref: "1", join_ref: "1"
      )
      decoded = JSON.parse(msg.to_json)
      expect(decoded).to eq(
        "event" => "phx_join", "topic" => "realtime:public:users",
        "payload" => { "config" => {} }, "ref" => "1", "join_ref" => "1"
      )
    end
  end
end
