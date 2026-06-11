# frozen_string_literal: true

require "securerandom"
require "supabase"
require "supabase/realtime"

# US-049 — Smoke integration test against a live Supabase Realtime server.
#
# Runs only when `SUPABASE_INTEGRATION_URL` is exported. Without it the spec is
# marked skipped so `bundle exec rspec` stays green in CI without a Supabase
# stack on the box.
#
# Local setup:
#
#   1. Bring up a local Supabase stack (`supabase start` from the Supabase
#      CLI, or `docker compose -f infra/docker-compose.yml up -d` if you
#      maintain your own stack — Realtime must be reachable).
#   2. Export the project URL and anon/publishable key:
#
#        export SUPABASE_INTEGRATION_URL=http://127.0.0.1:54321
#        export SUPABASE_INTEGRATION_KEY=<anon key from `supabase status`>
#
#   3. Run the spec:
#
#        bundle exec rspec spec/integration/realtime_smoke_spec.rb
#
# Scenario: connect → subscribe → broadcast send → broadcast receive →
# assert payload → unsubscribe. Total budget < 15 s; subscribe and receive
# waits are bounded at 5 s each with explicit error messages on timeout so a
# stopped/misconfigured stack surfaces immediately instead of hanging the run.
RSpec.describe "Realtime smoke integration (US-049)" do
  SUBSCRIBE_TIMEOUT_SECONDS = 5
  RECEIVE_TIMEOUT_SECONDS   = 5

  before do
    if (ENV["SUPABASE_INTEGRATION_URL"] || "").strip.empty?
      skip "SUPABASE_INTEGRATION_URL not set — see spec header for local setup"
    end
  end

  it "round-trips a broadcast frame against a live Supabase Realtime endpoint" do
    base_url = ENV.fetch("SUPABASE_INTEGRATION_URL").strip
    api_key  = (ENV["SUPABASE_INTEGRATION_KEY"] ||
                ENV["SUPABASE_ANON_KEY"] || "").strip

    realtime_url = base_url.sub(%r{\Ahttp://}, "ws://")
                           .sub(%r{\Ahttps://}, "wss://")
                           .chomp("/")
    realtime_url = "#{realtime_url}/realtime/v1"

    client = Supabase::Realtime::Client.new(
      url:                realtime_url,
      params:             { apikey: api_key },
      heartbeat_interval: 0,
      auto_reconnect:     false
    )

    state_queue   = Queue.new
    payload_queue = Queue.new

    channel = client.channel(
      "smoke-us049:#{SecureRandom.hex(4)}",
      params: {
        "config" => {
          "broadcast" => { "ack" => false, "self" => true },
          "presence"  => { "key" => "",    "enabled" => false },
          "private"   => false
        }
      }
    )
    channel.on_broadcast("ping") { |payload| payload_queue << payload }

    channel.subscribe { |state, err| state_queue << [state, err] }

    begin
      state, err = wait_for_queue(
        state_queue, SUBSCRIBE_TIMEOUT_SECONDS,
        "channel.subscribe did not complete within #{SUBSCRIBE_TIMEOUT_SECONDS}s " \
        "against #{realtime_url} (is the Supabase stack running?)"
      )

      unless state == Supabase::Realtime::Types::SubscribeStates::SUBSCRIBED
        raise "channel.subscribe returned state=#{state.inspect} err=#{err.inspect}"
      end

      expected_payload = { "hello" => "world", "nonce" => SecureRandom.hex(3) }
      channel.send_broadcast("ping", expected_payload)

      received = wait_for_queue(
        payload_queue, RECEIVE_TIMEOUT_SECONDS,
        "broadcast frame not received within #{RECEIVE_TIMEOUT_SECONDS}s after send " \
        "(channel topic=#{channel.topic.inspect})"
      )

      expect(received).to include(
        "event"   => "ping",
        "payload" => expected_payload
      )

      channel.unsubscribe
    ensure
      client.disconnect
    end
  end

  # Bounded blocking pop. We can't rely on `Queue#pop(timeout:)` which only
  # exists in Ruby 3.2+ (gemspec floor is 3.0). Polls non-blockingly so a
  # missed frame surfaces as a real RuntimeError with `error_message`,
  # never as a hung run.
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
