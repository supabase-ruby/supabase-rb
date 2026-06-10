# frozen_string_literal: true

require "supabase/realtime"
require "json"

# US-009 / F-C4: when two on_postgres_changes bindings share (schema, table)
# but use different `filter:` values, the server assigns each binding its own
# id at join time and tags every inbound change with the matching ids in
# payload.ids. The channel must use those server-assigned ids to demultiplex
# the callbacks — otherwise both bindings fire on every change and the
# per-filter selectivity that the user asked for collapses.
#
# Before the join-ack (no :id recorded yet) the legacy event/schema/table gate
# stays the sole filter, so application code that injects synthetic frames in
# tests doesn't have to mint ids.
RSpec.describe "US-009: postgres_changes dispatch by server-assigned ids" do
  let(:socket)  { Supabase::Realtime::TestSocket.new }
  let(:client)  { Supabase::Realtime::Client.new(url: "wss://x/v1", socket: socket) }
  let(:channel) { client.channel("realtime:public:users") }

  before { client.connect }

  def ack_join_with_ids(bindings)
    join_ref = socket.last_sent_frame["ref"]
    socket.inject(
      "event"   => "phx_reply",
      "topic"   => channel.topic,
      "payload" => { "status" => "ok", "response" => { "postgres_changes" => bindings } },
      "ref"     => join_ref,
      "join_ref" => join_ref
    )
  end

  describe "post-ack: two bindings, same (schema, table), different filter" do
    it "routes payload.ids: [first_id] only to the first binding (AC #3)" do
      first_calls  = []
      second_calls = []

      channel.on_postgres_changes(
        "INSERT", schema: "public", table: "users", filter: "id=eq.1"
      ) { |p| first_calls << p }

      channel.on_postgres_changes(
        "INSERT", schema: "public", table: "users", filter: "id=eq.2"
      ) { |p| second_calls << p }

      channel.subscribe
      ack_join_with_ids([
        { "id" => 10, "event" => "INSERT", "schema" => "public", "table" => "users", "filter" => "id=eq.1" },
        { "id" => 20, "event" => "INSERT", "schema" => "public", "table" => "users", "filter" => "id=eq.2" }
      ])

      socket.inject(
        "event"   => "postgres_changes",
        "topic"   => channel.topic,
        "payload" => {
          "data" => { "type" => "INSERT", "schema" => "public", "table" => "users", "record" => { "id" => 1 } },
          "ids"  => [10]
        }
      )

      expect(first_calls.size).to eq(1)
      expect(second_calls).to be_empty
    end

    it "routes payload.ids: [second_id] only to the second binding" do
      first_calls  = []
      second_calls = []

      channel.on_postgres_changes(
        "INSERT", schema: "public", table: "users", filter: "id=eq.1"
      ) { |p| first_calls << p }

      channel.on_postgres_changes(
        "INSERT", schema: "public", table: "users", filter: "id=eq.2"
      ) { |p| second_calls << p }

      channel.subscribe
      ack_join_with_ids([
        { "id" => 10, "event" => "INSERT", "schema" => "public", "table" => "users", "filter" => "id=eq.1" },
        { "id" => 20, "event" => "INSERT", "schema" => "public", "table" => "users", "filter" => "id=eq.2" }
      ])

      socket.inject(
        "event"   => "postgres_changes",
        "topic"   => channel.topic,
        "payload" => {
          "data" => { "type" => "INSERT", "schema" => "public", "table" => "users", "record" => { "id" => 2 } },
          "ids"  => [20]
        }
      )

      expect(first_calls).to be_empty
      expect(second_calls.size).to eq(1)
    end

    it "fires both bindings when payload.ids lists both binding ids" do
      first_calls  = []
      second_calls = []

      channel.on_postgres_changes(
        "INSERT", schema: "public", table: "users", filter: "id=eq.1"
      ) { |p| first_calls << p }

      channel.on_postgres_changes(
        "INSERT", schema: "public", table: "users", filter: "id=eq.2"
      ) { |p| second_calls << p }

      channel.subscribe
      ack_join_with_ids([
        { "id" => 10, "event" => "INSERT", "schema" => "public", "table" => "users", "filter" => "id=eq.1" },
        { "id" => 20, "event" => "INSERT", "schema" => "public", "table" => "users", "filter" => "id=eq.2" }
      ])

      socket.inject(
        "event"   => "postgres_changes",
        "topic"   => channel.topic,
        "payload" => {
          "data" => { "type" => "INSERT", "schema" => "public", "table" => "users" },
          "ids"  => [10, 20]
        }
      )

      expect(first_calls.size).to eq(1)
      expect(second_calls.size).to eq(1)
    end
  end

  describe "pre-ack (AC #2): id not yet recorded — legacy filter unchanged" do
    it "fires every event/schema/table-matching binding, ignoring payload.ids" do
      first_calls  = []
      second_calls = []

      channel.on_postgres_changes(
        "INSERT", schema: "public", table: "users", filter: "id=eq.1"
      ) { |p| first_calls << p }

      channel.on_postgres_changes(
        "INSERT", schema: "public", table: "users", filter: "id=eq.2"
      ) { |p| second_calls << p }

      channel.subscribe
      # Deliberately do not ack the join — bindings have no :id yet.

      socket.inject(
        "event"   => "postgres_changes",
        "topic"   => channel.topic,
        "payload" => {
          "data" => { "type" => "INSERT", "schema" => "public", "table" => "users" },
          "ids"  => [10]
        }
      )

      expect(first_calls.size).to eq(1)
      expect(second_calls.size).to eq(1)
    end

    it "post-ack: still fires the binding when the payload omits ids entirely" do
      # Belt-and-suspenders: a server frame without an "ids" key (e.g. an older
      # gateway, or a system change without binding attribution) must not be
      # silently dropped — fall back to the legacy event/schema/table gate.
      received = nil

      channel.on_postgres_changes(
        "INSERT", schema: "public", table: "users", filter: "id=eq.1"
      ) { |p| received = p }

      channel.subscribe
      ack_join_with_ids([
        { "id" => 10, "event" => "INSERT", "schema" => "public", "table" => "users", "filter" => "id=eq.1" }
      ])

      socket.inject(
        "event"   => "postgres_changes",
        "topic"   => channel.topic,
        "payload" => {
          "data" => { "type" => "INSERT", "schema" => "public", "table" => "users" }
        }
      )

      expect(received).not_to be_nil
    end
  end
end
