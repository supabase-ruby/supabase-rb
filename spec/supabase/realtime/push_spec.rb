# frozen_string_literal: true

require "supabase/realtime"

RSpec.describe Supabase::Realtime::Push do
  let(:push) { described_class.new(nil, "phx_join", { "config" => {} }, ref: "1") }

  it "fires the matching status handler when the reply lands" do
    received = nil
    push.receive("ok") { |p| received = p }

    push.resolve(status: "ok", payload: { "response" => "x" })
    expect(received).to eq("response" => "x")
  end

  it "ignores status handlers that don't match the reply" do
    fired = false
    push.receive("error") { fired = true }
    push.resolve(status: "ok", payload: {})
    expect(fired).to be false
  end

  it "fires immediately if the handler is attached AFTER the reply already landed" do
    push.resolve(status: "ok", payload: { "x" => 1 })

    fired = nil
    push.receive("ok") { |p| fired = p }
    expect(fired).to eq("x" => 1)
  end

  it "translates #time_out into a 'timeout' resolve so timeout handlers fire" do
    fired = false
    push.receive("timeout") { fired = true }
    push.time_out
    expect(fired).to be true
  end

  it "is chainable so receive(...).receive(...) reads naturally" do
    expect(push.receive("ok") { }).to be(push)
  end

  describe "#start_timeout" do
    it "fires the timeout handler after the configured delay" do
      fired = false
      push.receive("timeout") { fired = true }
      push.start_timeout(0.05)
      sleep 0.15
      expect(fired).to be true
    end

    it "does not double-fire when an ack arrives after the timeout" do
      counter = 0
      push.receive("timeout") { counter += 1 }
      push.receive("ok")      { counter += 1 }
      push.start_timeout(0.05)
      sleep 0.15
      push.resolve(status: "ok", payload: {})
      expect(counter).to eq(1)
    end

    it "is cancelled by a successful resolve" do
      counter = 0
      push.receive("timeout") { counter += 1 }
      push.start_timeout(0.05)
      push.resolve(status: "ok", payload: {})
      sleep 0.15
      expect(counter).to eq(0)
    end
  end
end
