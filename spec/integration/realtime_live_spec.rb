# frozen_string_literal: true

require "securerandom"
require "time"
require "supabase"
require "supabase/realtime"

# US-051 — Live integration parity suite for Realtime, mirroring supabase-py's
# `src/realtime/tests/test_connection.py` and `test_presence.py` (which run
# against a real Supabase stack, not mocks).
#
# Gated exactly like the US-049 smoke spec: runs only when
# `SUPABASE_INTEGRATION_URL` is exported, otherwise every example is skipped so
# CI stays green without a stack on the box.
#
#   export SUPABASE_INTEGRATION_URL=http://127.0.0.1:54321
#   export SUPABASE_INTEGRATION_KEY=<anon key from `supabase status`>
#   bundle exec rspec spec/integration/realtime_live_spec.rb
#
# Coverage map (py → rb):
#   test_broadcast_events                → "delivers broadcasts in order"
#   test_presence                        → "tracks and untracks presence"
#   test_postgrest_changes               → "routes postgres_changes by event"
#   (US-050 follow-up, no py equivalent) → "tears down channels via the umbrella"
#
# The postgres_changes example additionally needs a `public.todos` table
# (description text, is_completed bool) with realtime enabled and open signup —
# same assumptions as the Python test. It self-skips with a reason when the
# stack doesn't provide them, so the rest of the suite still runs.
RSpec.describe "Realtime live integration (US-051)" do
  STEP_TIMEOUT_SECONDS = 10

  before do
    if (ENV["SUPABASE_INTEGRATION_URL"] || "").strip.empty?
      skip "SUPABASE_INTEGRATION_URL not set — see spec header for local setup"
    end
  end

  let(:base_url) { ENV.fetch("SUPABASE_INTEGRATION_URL").strip.chomp("/") }
  let(:api_key) do
    (ENV["SUPABASE_INTEGRATION_KEY"] || ENV["SUPABASE_ANON_KEY"] || "").strip
  end
  let(:realtime_url) do
    base_url.sub(%r{\Ahttp://}, "ws://").sub(%r{\Ahttps://}, "wss://") + "/realtime/v1"
  end

  def build_realtime_client
    Supabase::Realtime::Client.new(
      url:            realtime_url,
      params:         { apikey: api_key },
      auto_reconnect: false
    )
  end

  def subscribe_and_wait(channel)
    states = Queue.new
    channel.subscribe { |state, err| states << [state, err] }
    state, err = wait_for_queue(states, STEP_TIMEOUT_SECONDS,
                                "subscribe did not complete against #{realtime_url}")
    unless state == Supabase::Realtime::Types::SubscribeStates::SUBSCRIBED
      raise "subscribe failed: state=#{state.inspect} err=#{err.inspect}"
    end
  end

  # --- py: test_broadcast_events -------------------------------------------

  it "delivers self-broadcasts in send order" do
    client = build_realtime_client
    received = Queue.new

    channel = client.channel(
      "live-us051-broadcast:#{SecureRandom.hex(4)}",
      params: { "config" => {
        "broadcast" => { "ack" => true, "self" => true },
        "presence"  => { "key" => "", "enabled" => false },
        "private"   => false
      } }
    )
    channel.on_broadcast("test-event") { |payload| received << payload }

    begin
      subscribe_and_wait(channel)

      events = 3.times.map do |i|
        channel.send_broadcast("test-event", { "message" => "Event #{i + 1}" })
        wait_for_queue(received, STEP_TIMEOUT_SECONDS, "broadcast #{i + 1} not received")
      end

      events.each_with_index do |event, i|
        expect(event["payload"]).to eq({ "message" => "Event #{i + 1}" }),
                                    "broadcast #{i + 1} arrived out of order: #{events.inspect}"
      end

      channel.unsubscribe
    ensure
      client.disconnect
    end
  end

  # --- py: test_presence -----------------------------------------------------

  it "tracks and untracks presence with sync/join/leave callbacks" do
    client = build_realtime_client
    syncs  = Queue.new
    joins  = Queue.new
    leaves = Queue.new

    channel = client.channel(
      "live-us051-presence:#{SecureRandom.hex(4)}",
      params: { "config" => {
        "broadcast" => { "ack" => false, "self" => false },
        "presence"  => { "key" => "", "enabled" => true },
        "private"   => false
      } }
    )
    channel.on_presence_sync { syncs << true }
    channel.on_presence_join { |key, current, fresh| joins << [key, current, fresh] }
    channel.on_presence_leave { |key, remaining, left| leaves << [key, remaining, left] }

    begin
      subscribe_and_wait(channel)
      # First sync arrives right after join — drain it like the py test does.
      wait_for_queue(syncs, STEP_TIMEOUT_SECONDS, "initial presence sync not received")

      user = { "user_id" => "1", "online_at" => Time.now.utc.iso8601 }
      channel.track(user)
      wait_for_queue(syncs, STEP_TIMEOUT_SECONDS, "sync after track not received")

      state = channel.presence_state
      expect(state.size).to eq(1)
      meta = state.values.first.first
      expect(meta["user_id"]).to eq("1")
      expect(meta["online_at"]).to eq(user["online_at"])
      expect(meta).to have_key("presence_ref")

      _key, _current, fresh = wait_for_queue(joins, STEP_TIMEOUT_SECONDS,
                                             "join callback not fired after track")
      expect(fresh.first["user_id"]).to eq("1")
      expect(fresh.first).to have_key("presence_ref")

      channel.untrack
      wait_for_queue(syncs, STEP_TIMEOUT_SECONDS, "sync after untrack not received")

      expect(channel.presence_state).to eq({})
      _key, _remaining, left = wait_for_queue(leaves, STEP_TIMEOUT_SECONDS,
                                              "leave callback not fired after untrack")
      expect(left.first["user_id"]).to eq("1")

      channel.unsubscribe
    ensure
      client.disconnect
    end
  end

  # --- py: test_postgrest_changes ---------------------------------------------

  it "routes postgres_changes INSERT/UPDATE/DELETE to per-event and wildcard listeners" do
    rest = Supabase.create_client(supabase_url: base_url, supabase_key: api_key)

    token = begin
      response = rest.auth.sign_up(
        email:    "test_#{Time.now.strftime('%Y%m%d%H%M%S%L')}@example.com",
        password: "test.123"
      )
      response.session&.access_token
    rescue StandardError => e
      skip "signup unavailable on this stack (#{e.class}: #{e.message})"
    end
    skip "signup did not return a session (email confirmation enabled?)" if token.nil?

    rest.set_auth(token)

    client = build_realtime_client
    client.set_auth(token)

    all_events = []
    inserts = Queue.new
    updates = Queue.new
    deletes = Queue.new

    channel = client.channel("live-us051-pgchanges:#{SecureRandom.hex(4)}")
    channel
      .on_postgres_changes("*", table: "todos") { |payload| all_events << payload }
      .on_postgres_changes("INSERT", table: "todos") { |payload| inserts << payload }
      .on_postgres_changes("UPDATE", table: "todos") { |payload| updates << payload }
      .on_postgres_changes("DELETE", table: "todos") { |payload| deletes << payload }

    begin
      subscribe_and_wait(channel)

      todo_id = begin
        resp = rest.from("todos")
                   .insert({ "description" => "Test todo", "is_completed" => false })
                   .execute
        resp.data.first["id"]
      rescue Supabase::Postgrest::Errors::APIError => e
        skip "todos table unavailable on this stack (#{e.message})"
      end

      insert_payload = wait_for_queue(inserts, STEP_TIMEOUT_SECONDS,
                                      "INSERT change not received (is realtime enabled for public.todos?)")
      record = insert_payload.dig("data", "record")
      expect(record["id"]).to eq(todo_id)
      expect(record["description"]).to eq("Test todo")
      expect(record["is_completed"]).to eq(false)

      rest.from("todos")
          .update({ "description" => "Updated todo", "is_completed" => true })
          .eq("id", todo_id)
          .execute
      update_payload = wait_for_queue(updates, STEP_TIMEOUT_SECONDS, "UPDATE change not received")
      expect(update_payload.dig("data", "record", "description")).to eq("Updated todo")
      expect(update_payload.dig("data", "record", "is_completed")).to eq(true)

      rest.from("todos").delete.eq("id", todo_id).execute
      delete_payload = wait_for_queue(deletes, STEP_TIMEOUT_SECONDS, "DELETE change not received")
      expect(delete_payload.dig("data", "old_record", "id")).to eq(todo_id)

      # Wildcard listener saw all three, in commit order — same assertion as py.
      expect(all_events.size).to eq(3)
      expect(all_events).to eq([insert_payload, update_payload, delete_payload])

      channel.unsubscribe
    ensure
      client.disconnect
    end
  end

  # --- US-050 follow-up: umbrella teardown against a live socket --------------

  it "tears down channels via the umbrella client (remove_channel / remove_all_channels)" do
    umbrella = Supabase.create_client(supabase_url: base_url, supabase_key: api_key)
    # Point the umbrella's realtime at the integration stack the same way the
    # other examples do (create_client derives the URL from supabase_url, which
    # already matches base_url — this just makes the wiring explicit).
    realtime = umbrella.realtime

    channel_a = umbrella.channel("live-us051-teardown-a:#{SecureRandom.hex(4)}")
    channel_b = umbrella.channel("live-us051-teardown-b:#{SecureRandom.hex(4)}")

    begin
      subscribe_and_wait(channel_a)
      subscribe_and_wait(channel_b)
      expect(umbrella.get_channels).to contain_exactly(channel_a, channel_b)

      umbrella.remove_channel(channel_a)
      expect(umbrella.get_channels).to contain_exactly(channel_b)

      umbrella.remove_all_channels
      expect(umbrella.get_channels).to be_empty
      # Realtime client closes the socket once the registry empties.
      expect(realtime.connected?).to be(false)
    ensure
      realtime.disconnect
    end
  end

  # Bounded blocking pop — same rationale as the US-049 smoke spec: no
  # `Queue#pop(timeout:)` below Ruby 3.2, and a missed frame must surface as a
  # RuntimeError with context, never a hung run.
  def wait_for_queue(queue, seconds, error_message)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    loop do
      begin
        return queue.pop(true)
      rescue ThreadError
        # queue empty — fall through to wait
      end

      raise error_message if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.05
    end
  end
end
