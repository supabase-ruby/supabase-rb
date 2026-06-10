# frozen_string_literal: true

require "supabase/realtime"

RSpec.describe Supabase::Realtime::Presence do
  let(:presence) { described_class.new }

  # Wire format Phoenix sends — each key maps to
  # { "metas" => [{ "phx_ref" => "...", arbitrary => ... }] }
  # The transformed (stored) shape is { key => [{ "presence_ref" => ..., ... }, ...] }.
  def state_of(refs)
    refs.transform_values { |ref| { "metas" => [{ "phx_ref" => ref, "user" => "u_#{ref}" }] } }
  end

  describe "#sync_state (first snapshot after joining)" do
    it "replaces the local state with the server snapshot and emits joins for everything" do
      joins = []
      presence.on_join { |key, current, new_presences| joins << [key, current, new_presences] }

      result = presence.sync_state(state_of("a" => "r1", "b" => "r2"))

      expect(result.keys).to contain_exactly("a", "b")
      expect(result["a"]).to eq([{ "presence_ref" => "r1", "user" => "u_r1" }])
      expect(joins.map(&:first)).to contain_exactly("a", "b")
      expect(joins.map { |j| j[1] }).to all(eq([]))
      expect(joins.find { |j| j.first == "a" }[2]).to eq([{ "presence_ref" => "r1", "user" => "u_r1" }])
    end

    it "fires leaves for keys the server no longer sees" do
      presence.sync_state(state_of("a" => "r1"))
      leaves = []
      presence.on_leave { |key, _current, _left| leaves << key }

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
      expect(presence.state["a"].map { |m| m["presence_ref"] }).to contain_exactly("r1", "r1b")
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

      expect(presence.state["a"].map { |m| m["presence_ref"] }).to contain_exactly("r1b")
    end

    it "passes current and new presence lists to on_join callbacks" do
      received = []
      presence.on_join { |key, current, new_presences| received << [key, current, new_presences] }

      presence.sync_diff(
        "joins"  => { "a" => { "metas" => [{ "phx_ref" => "r1b", "user" => "u_r1b" }] } },
        "leaves" => {}
      )

      key, current, new_presences = received.first
      expect(key).to eq("a")
      expect(current).to eq([{ "presence_ref" => "r1", "user" => "u_r1" }])
      expect(new_presences).to eq([{ "presence_ref" => "r1b", "user" => "u_r1b" }])
    end
  end

  describe "#list" do
    it "flattens every presence across all keys" do
      presence.sync_state(state_of("a" => "r1", "b" => "r2"))
      expect(presence.list.map { |m| m["presence_ref"] }).to contain_exactly("r1", "r2")
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
