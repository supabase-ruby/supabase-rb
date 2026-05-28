# frozen_string_literal: true

require "supabase/realtime"

RSpec.describe Supabase::Realtime::Presence do
  let(:presence) { described_class.new }

  # Sample states use the wire format Phoenix sends — each key maps to
  # { "metas" => [{ "phx_ref" => "...", arbitrary => ... }] }
  def state_of(refs)
    refs.transform_values { |ref| { "metas" => [{ "phx_ref" => ref, "user" => "u_#{ref}" }] } }
  end

  describe "#sync_state (first snapshot after joining)" do
    it "replaces the local state with the server snapshot and emits joins for everything" do
      joins = []
      presence.on_join { |key, p| joins << [key, p] }

      result = presence.sync_state(state_of("a" => "r1", "b" => "r2"))

      expect(result.keys).to contain_exactly("a", "b")
      expect(joins.map(&:first)).to contain_exactly("a", "b")
    end

    it "fires leaves for keys the server no longer sees" do
      presence.sync_state(state_of("a" => "r1"))
      leaves = []
      presence.on_leave { |key, _| leaves << key }

      presence.sync_state(state_of("b" => "r2"))
      expect(leaves).to contain_exactly("a")
    end

    it "fires on_sync after every state replacement" do
      counter = 0
      presence.on_sync { counter += 1 }

      presence.sync_state(state_of("a" => "r1"))
      presence.sync_state(state_of("a" => "r1"))
      expect(counter).to eq(2)
    end
  end

  describe "#sync_diff (incremental updates)" do
    before { presence.sync_state(state_of("a" => "r1")) }

    it "adds new keys from joins" do
      presence.sync_diff(
        "joins"  => state_of("b" => "r2"),
        "leaves" => {}
      )
      expect(presence.state.keys).to contain_exactly("a", "b")
    end

    it "appends new metas to existing keys without dropping the old ones" do
      presence.sync_diff(
        "joins"  => { "a" => { "metas" => [{ "phx_ref" => "r1b", "user" => "u_r1b" }] } },
        "leaves" => {}
      )
      expect(presence.state["a"]["metas"].map { |m| m["phx_ref"] }).to contain_exactly("r1", "r1b")
    end

    it "removes the whole key when its last meta leaves" do
      presence.sync_diff("joins" => {}, "leaves" => state_of("a" => "r1"))
      expect(presence.state).to be_empty
    end

    it "drops only the leaving meta if other metas remain under the same key" do
      presence.sync_diff(
        "joins" => { "a" => { "metas" => [{ "phx_ref" => "r1b" }] } },
        "leaves" => {}
      )
      presence.sync_diff(
        "joins"  => {},
        "leaves" => { "a" => { "metas" => [{ "phx_ref" => "r1" }] } }
      )

      expect(presence.state["a"]["metas"].map { |m| m["phx_ref"] }).to contain_exactly("r1b")
    end
  end

  describe "#list" do
    it "flattens every meta across all keys" do
      presence.sync_state(state_of("a" => "r1", "b" => "r2"))
      expect(presence.list.map { |m| m["phx_ref"] }).to contain_exactly("r1", "r2")
    end
  end

  describe "#any_callbacks?" do
    it "is false until at least one listener is attached" do
      expect(presence.any_callbacks?).to be false
      presence.on_sync { }
      expect(presence.any_callbacks?).to be true
    end
  end
end
