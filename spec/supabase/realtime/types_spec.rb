# frozen_string_literal: true

require "supabase/realtime"

RSpec.describe Supabase::Realtime::Types do
  describe "module-level constants" do
    it "speaks Phoenix protocol version 1.0.0" do
      expect(described_class::VSN).to eq("1.0.0")
    end

    it "exposes the special 'phoenix' topic used for heartbeats" do
      expect(described_class::PHOENIX_TOPIC).to eq("phoenix")
    end
  end

  describe described_class::ChannelEvents do
    it "matches supabase-py's ChannelEvents enum 1:1" do
      expect(described_class::JOIN).to             eq("phx_join")
      expect(described_class::CLOSE).to            eq("phx_close")
      expect(described_class::ERROR).to            eq("phx_error")
      expect(described_class::REPLY).to            eq("phx_reply")
      expect(described_class::LEAVE).to            eq("phx_leave")
      expect(described_class::HEARTBEAT).to        eq("heartbeat")
      expect(described_class::ACCESS_TOKEN).to     eq("access_token")
      expect(described_class::BROADCAST).to        eq("broadcast")
      expect(described_class::PRESENCE).to         eq("presence")
      expect(described_class::PRESENCE_STATE).to   eq("presence_state")
      expect(described_class::PRESENCE_DIFF).to    eq("presence_diff")
      expect(described_class::SYSTEM).to           eq("system")
      expect(described_class::POSTGRES_CHANGES).to eq("postgres_changes")
    end
  end

  describe described_class::ChannelStates do
    it "covers the five lifecycle states as symbols" do
      expect(described_class::ALL)
        .to contain_exactly(:closed, :errored, :joined, :joining, :leaving)
    end
  end

  describe described_class::SubscribeStates do
    it "uses the JS client's all-caps subscribe states for callback parity" do
      expect(described_class::SUBSCRIBED).to    eq("SUBSCRIBED")
      expect(described_class::TIMED_OUT).to     eq("TIMED_OUT")
      expect(described_class::CLOSED).to        eq("CLOSED")
      expect(described_class::CHANNEL_ERROR).to eq("CHANNEL_ERROR")
    end
  end

  describe described_class::AckStatus do
    it "defines ok/error/timeout (the only three values phx_reply.status takes)" do
      expect(described_class::OK).to      eq("ok")
      expect(described_class::ERROR).to   eq("error")
      expect(described_class::TIMEOUT).to eq("timeout")
    end
  end
end
