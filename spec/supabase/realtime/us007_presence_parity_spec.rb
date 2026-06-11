# frozen_string_literal: true

require "supabase/realtime"

# US-007: Realtime — портировать py-тесты presence/timer + стресс-спек
# тред-безопасности.
#
# Этот файл — порт `client/supabase-py/src/realtime/tests/test_presence.py` на rb,
# плюс рег-кейсы на порядок join/leave и удаление ключей. Живой
# E2E-`test_presence` из py (он гоняется против локального supabase-стэка)
# воспроизводится здесь через {Supabase::Realtime::TestSocket}: инъекцируем
# `presence_state`/`presence_diff`-фреймы прямо с транспорта и проверяем,
# что наблюдаемое поведение совпадает с py 1:1.
#
# Эталоны:
# - py `test_presence.py::test_presence`              — порядок join/leave;
# - py `test_presence.py::test_transform_state_*`     — transform_state;
# - py `test_presence.py::test_presence_has_callback_attached` — any_callbacks?
RSpec.describe "US-007: presence parity with supabase-py" do
  let(:presence) { Supabase::Realtime::Presence.new }

  # Same wire shape Phoenix sends: `{ key => { "metas" => [{ "phx_ref" => "..." }] } }`.
  def state_of(refs)
    refs.transform_values { |ref| { "metas" => [{ "phx_ref" => ref, "user" => "u_#{ref}" }] } }
  end

  describe "py test_presence — join/leave order & key removal (live flow)" do
    let(:socket) { Supabase::Realtime::TestSocket.new }
    let(:client) do
      Supabase::Realtime::Client.new(
        url: "wss://x/v1",
        socket: socket,
        heartbeat_interval: 0,
        auto_reconnect: false
      )
    end
    let(:channel) { client.channel("room") }

    before { client.connect }

    def ack_join(ch)
      join_ref = JSON.parse(
        socket.sent_frames.reverse.find { |f| JSON.parse(f)["topic"] == ch.topic }
      )["ref"]
      socket.inject(
        "event"    => "phx_reply",
        "topic"    => ch.topic,
        "payload"  => { "status" => "ok", "response" => {} },
        "ref"      => join_ref,
        "join_ref" => join_ref
      )
    end

    def inject_presence_state(ch, raw)
      socket.inject("event" => "presence_state", "topic" => ch.topic, "payload" => raw)
    end

    def inject_presence_diff(ch, joins: {}, leaves: {})
      socket.inject(
        "event"   => "presence_diff",
        "topic"   => ch.topic,
        "payload" => { "joins" => joins, "leaves" => leaves }
      )
    end

    it "(test_presence) initial sync emits one join with user1; tracking user2 emits a second join; untrack emits two leaves" do
      sync_events  = []
      join_events  = []
      leave_events = []

      channel
        .on_presence_sync  { sync_events  << :tick }
        .on_presence_join  { |key, current, new_p| join_events  << [key, current, new_p] }
        .on_presence_leave { |key, current, left| leave_events << [key, current, left] }
        .subscribe

      ack_join(channel)

      # First sync (immediate after join) — empty state per py's mock server.
      inject_presence_state(channel, {})
      expect(sync_events.size).to eq(1)
      expect(join_events).to be_empty
      expect(channel.presence_state).to eq({})

      # User 1 joins (presence_diff with one join, no leaves).
      user1 = { "user_id" => "1", "online_at" => "2026-06-11T00:00:00Z" }
      inject_presence_diff(channel,
        joins: { "1" => { "metas" => [{ "phx_ref" => "ref1" }.merge(user1)] } })

      # py assertions: exactly one presence under one key, with presence_ref
      # populated and user-supplied fields preserved.
      state = channel.presence_state
      expect(state.keys).to contain_exactly("1")
      expect(state["1"].length).to eq(1)
      expect(state["1"][0]).to include("user_id" => "1", "online_at" => "2026-06-11T00:00:00Z")
      expect(state["1"][0]).to include("presence_ref" => "ref1")

      expect(join_events.length).to eq(1)
      key, current, new_p = join_events[0]
      expect(key).to eq("1")
      expect(current).to eq([])
      expect(new_p.length).to eq(1)
      expect(new_p[0]).to include("user_id" => "1", "presence_ref" => "ref1")

      # User 2 joins under a separate key — second join event fires with the
      # new user only (py contract: current_presences for a brand-new key is []).
      user2 = { "user_id" => "2", "online_at" => "2026-06-11T00:00:01Z" }
      inject_presence_diff(channel,
        joins: { "2" => { "metas" => [{ "phx_ref" => "ref2" }.merge(user2)] } })

      state = channel.presence_state
      expect(state.keys).to contain_exactly("1", "2")
      expect(state.values.flatten.length).to eq(2)
      state.each_value do |presences|
        expect(presences.length).to eq(1)
        expect(%w[1 2]).to include(presences[0]["user_id"])
        expect(presences[0]).to have_key("online_at")
        expect(presences[0]).to have_key("presence_ref")
      end

      expect(join_events.length).to eq(2)
      key, current, new_p = join_events[1]
      expect(key).to eq("2")
      expect(current).to eq([])
      expect(new_p.length).to eq(1)
      expect(new_p[0]).to include("user_id" => "2", "presence_ref" => "ref2")

      # Untrack both users at once (one diff with two leaves) — py asserts the
      # state is fully empty and TWO leave events were fired, one per key.
      inject_presence_diff(channel,
        leaves: {
          "1" => { "metas" => [{ "phx_ref" => "ref1" }.merge(user1)] },
          "2" => { "metas" => [{ "phx_ref" => "ref2" }.merge(user2)] }
        })

      expect(channel.presence_state).to eq({})
      expect(leave_events.length).to eq(2)
      expect(leave_events.map(&:first)).to contain_exactly("1", "2")
      # py: `leave_events[0] != leave_events[1]` — distinct keys, distinct payloads.
      expect(leave_events[0]).not_to eq(leave_events[1])
    end

    it "removes the key from state immediately when its last meta leaves (py parity)" do
      channel.subscribe
      ack_join(channel)
      inject_presence_state(channel, state_of("a" => "ref_a"))
      expect(channel.presence_state.keys).to contain_exactly("a")

      inject_presence_diff(channel, leaves: state_of("a" => "ref_a"))
      # py `_sync_diff` deletes the key once `remaining` is empty.
      expect(channel.presence_state).to eq({})
    end

    it "preserves join ORDER when several keys appear in the same diff (rb-Hash insertion order = py-dict order)" do
      ordered_joins = []
      channel.on_presence_join { |key, _c, _n| ordered_joins << key }.subscribe
      ack_join(channel)

      inject_presence_diff(channel, joins: state_of("a" => "r_a", "b" => "r_b", "c" => "r_c"))

      expect(ordered_joins).to eq(%w[a b c])
    end

    it "applies joins BEFORE leaves in the same presence_diff (py: _sync_diff iterates joins, then leaves)" do
      events = []
      channel
        .on_presence_join  { |key, _c, _n| events << [:join,  key] }
        .on_presence_leave { |key, _c, _l| events << [:leave, key] }
        .subscribe
      ack_join(channel)
      # Seed "a" via presence_state; ignore the synthetic [:join, "a"] event so
      # the assertion below isolates the join-vs-leave ordering INSIDE a single
      # presence_diff (which is the py contract under test here).
      inject_presence_state(channel, state_of("a" => "r_a"))
      events.clear

      inject_presence_diff(channel,
        joins:  state_of("b" => "r_b"),
        leaves: state_of("a" => "r_a"))

      # py contract: joins fan out first, leaves second.
      expect(events).to eq([[:join, "b"], [:leave, "a"]])
    end
  end

  describe "py test_transform_state_raw_presence_state" do
    it "lowers wire { metas: [{ phx_ref, ... }] } to flat { presence_ref, ... } and drops phx_ref_prev" do
      raw = {
        "user1" => {
          "metas" => [
            { "phx_ref" => "ABC123", "user_id" => "user1", "status" => "online" },
            { "phx_ref" => "DEF456", "phx_ref_prev" => "ABC123", "user_id" => "user1", "status" => "away" }
          ]
        },
        "user2" => {
          "metas" => [
            { "phx_ref" => "GHI789", "user_id" => "user2", "status" => "offline" }
          ]
        }
      }

      expected = {
        "user1" => [
          { "presence_ref" => "ABC123", "user_id" => "user1", "status" => "online" },
          { "presence_ref" => "DEF456", "user_id" => "user1", "status" => "away" }
        ],
        "user2" => [
          { "presence_ref" => "GHI789", "user_id" => "user2", "status" => "offline" }
        ]
      }

      expect(Supabase::Realtime::Presence.transform_state(raw)).to eq(expected)
    end
  end

  describe "py test_transform_state_empty_input" do
    it "returns an empty hash for an empty input (and tolerates nil)" do
      expect(Supabase::Realtime::Presence.transform_state({})).to eq({})
      expect(Supabase::Realtime::Presence.transform_state(nil)).to eq({})
    end
  end

  describe "py test_transform_state_additional_fields" do
    it "preserves arbitrary user-supplied fields verbatim under the new presence_ref" do
      raw = {
        "user1" => {
          "metas" => [
            { "phx_ref" => "ABC123", "user_id" => "user1", "status" => "online", "extra" => "data" }
          ]
        }
      }
      expected = {
        "user1" => [
          { "presence_ref" => "ABC123", "user_id" => "user1", "status" => "online", "extra" => "data" }
        ]
      }
      expect(Supabase::Realtime::Presence.transform_state(raw)).to eq(expected)
    end
  end

  describe "py test_presence_has_callback_attached (rb: #any_callbacks?)" do
    it "is false until at least one sync/join/leave callback is attached" do
      expect(presence.any_callbacks?).to be false
    end

    it "is true after on_sync" do
      presence.on_sync { }
      expect(presence.any_callbacks?).to be true
    end

    it "is true after on_join only" do
      fresh = Supabase::Realtime::Presence.new
      fresh.on_join { |_k, _c, _n| }
      expect(fresh.any_callbacks?).to be true
    end

    it "is true after on_leave only" do
      fresh = Supabase::Realtime::Presence.new
      fresh.on_leave { |_k, _c, _l| }
      expect(fresh.any_callbacks?).to be true
    end
  end
end
