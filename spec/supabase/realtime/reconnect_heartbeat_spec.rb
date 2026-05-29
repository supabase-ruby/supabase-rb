# frozen_string_literal: true

require "supabase/realtime"
require "json"

# Covers the three production-readiness gaps surfaced when porting from supabase-py:
#   - postgres_changes bindings must be sent in the join payload so the server filters
#   - the client must automatically emit heartbeats while the socket is open
#   - the client must automatically reconnect (with exponential backoff) on
#     unexpected close, and rejoin any channels that had been subscribed
RSpec.describe "Realtime production-readiness fixes" do
  let(:socket) { Supabase::Realtime::TestSocket.new }

  describe "postgres_changes bindings in join payload" do
    let(:client) do
      Supabase::Realtime::Client.new(
        url: "wss://x/v1",
        socket: socket,
        heartbeat_interval: 0 # disable so the spec stays synchronous
      )
    end
    let(:channel) { client.channel("realtime:public:users") }

    before { client.connect }

    it "serializes registered listeners into config.postgres_changes" do
      channel.on_postgres_changes("INSERT", schema: "public", table: "users") { }
      channel.on_postgres_changes("UPDATE", schema: "public", table: "users", filter: "id=eq.42") { }
      channel.subscribe

      bindings = socket.last_sent_frame["payload"]["config"]["postgres_changes"]
      expect(bindings).to contain_exactly(
        { "event" => "INSERT", "schema" => "public", "table" => "users" },
        { "event" => "UPDATE", "schema" => "public", "table" => "users", "filter" => "id=eq.42" }
      )
    end

    it "sends an empty postgres_changes array when no listeners are registered" do
      channel.subscribe
      expect(socket.last_sent_frame["payload"]["config"]["postgres_changes"]).to eq([])
    end

    it "omits schema/table/filter keys when nil rather than sending nulls" do
      channel.on_postgres_changes("*") { }
      channel.subscribe

      binding = socket.last_sent_frame["payload"]["config"]["postgres_changes"].first
      expect(binding).to eq("event" => "*")
    end
  end

  describe "automatic heartbeat" do
    it "fires send_heartbeat on the configured interval while connected" do
      client = Supabase::Realtime::Client.new(
        url: "wss://x/v1",
        socket: socket,
        heartbeat_interval: 0.05
      )
      client.connect

      # Wait a bit so two ticks land. The TestSocket records every send_frame.
      sleep 0.18
      hb_count = socket.sent_events.count("heartbeat")
      expect(hb_count).to be >= 2

      client.disconnect
    end

    it "stops firing heartbeats after disconnect" do
      client = Supabase::Realtime::Client.new(
        url: "wss://x/v1",
        socket: socket,
        heartbeat_interval: 0.05
      )
      client.connect
      sleep 0.12
      client.disconnect

      before_count = socket.sent_events.count("heartbeat")
      sleep 0.15
      after_count = socket.sent_events.count("heartbeat")
      expect(after_count).to eq(before_count)
    end

    it "is disabled when heartbeat_interval is 0" do
      client = Supabase::Realtime::Client.new(
        url: "wss://x/v1",
        socket: socket,
        heartbeat_interval: 0
      )
      client.connect
      sleep 0.08
      expect(socket.sent_events).not_to include("heartbeat")
      client.disconnect
    end
  end

  describe "automatic reconnect on unexpected close" do
    # A TestSocket variant that lets the spec script connect attempts: each
    # close() triggers the client's on_close handler, and the spec can later
    # observe whether the client called connect() again.
    let(:reconnect_socket) do
      Class.new(Supabase::Realtime::TestSocket) do
        attr_reader :connect_count

        def initialize
          super
          @connect_count = 0
        end

        def connect
          @connect_count += 1
          super
        end

        # Simulate the server (or network) yanking the connection.
        def fire_close
          @connected = false
          close_callbacks.each(&:call)
        end
      end.new
    end

    let(:client) do
      Supabase::Realtime::Client.new(
        url: "wss://x/v1",
        socket: reconnect_socket,
        heartbeat_interval: 0,
        initial_backoff: 0.02,
        max_retries: 3
      )
    end

    it "reconnects after an unexpected close" do
      client.connect
      expect(reconnect_socket.connect_count).to eq(1)

      reconnect_socket.fire_close
      sleep 0.08
      expect(reconnect_socket.connect_count).to be >= 2
      client.disconnect
    end

    it "does NOT reconnect when disconnect() was called explicitly" do
      client.connect
      client.disconnect

      sleep 0.08
      # The initial connect counts as 1; disconnect must not trigger another.
      expect(reconnect_socket.connect_count).to eq(1)
    end

    it "stops after max_retries failed attempts" do
      # Make connect() raise so retries always fail, so we can verify the cap.
      reconnect_socket.define_singleton_method(:connect) do
        @connect_count += 1
        raise "boom"
      end

      expect { client.connect }.to raise_error("boom")
      sleep 0.5 # let backoffs complete (0.02 + 0.04 + 0.08 + 0.16 < 500ms)

      # 1 from the initial connect() + 3 retries = 4. Anything beyond that
      # would mean max_retries didn't apply.
      expect(reconnect_socket.connect_count).to be <= 1 + 3
      client.disconnect
    end

    it "re-issues phx_join for previously-subscribed channels after reconnect" do
      channel = client.channel("realtime:public:posts")
      channel.subscribe
      # Simulate server ack so channel.@joined_once stays true and state is JOINED.
      join_ref = reconnect_socket.last_sent_frame["ref"]
      reconnect_socket.inject(
        "event"    => "phx_reply",
        "topic"    => channel.topic,
        "payload"  => { "status" => "ok", "response" => {} },
        "ref"      => join_ref,
        "join_ref" => join_ref
      )
      expect(channel).to be_joined

      reconnect_socket.reset_sent_frames
      reconnect_socket.fire_close
      sleep 0.08

      join_frames = reconnect_socket.sent_frames
        .map { |f| JSON.parse(f) }
        .select { |f| f["event"] == "phx_join" && f["topic"] == channel.topic }
      expect(join_frames).not_to be_empty
      expect(channel).to be_joining
      client.disconnect
    end

    it "honours auto_reconnect: false" do
      no_reconnect_client = Supabase::Realtime::Client.new(
        url: "wss://x/v1",
        socket: reconnect_socket,
        heartbeat_interval: 0,
        auto_reconnect: false
      )
      no_reconnect_client.connect
      reconnect_socket.fire_close
      sleep 0.05
      expect(reconnect_socket.connect_count).to eq(1)
      no_reconnect_client.disconnect
    end
  end

  describe "Channel#rejoin" do
    let(:client) do
      Supabase::Realtime::Client.new(url: "wss://x/v1", socket: socket, heartbeat_interval: 0)
    end
    let(:channel) { client.channel("realtime:public:items") }

    before { client.connect }

    it "is a no-op for a channel that was never subscribed" do
      channel.rejoin
      expect(socket.sent_frames).to be_empty
      expect(channel).to be_closed
    end

    it "sends a fresh phx_join and resets state to JOINING" do
      channel.on_postgres_changes("INSERT", schema: "public", table: "items") { }
      channel.subscribe
      join_ref = socket.last_sent_frame["ref"]
      socket.inject(
        "event"    => "phx_reply",
        "topic"    => channel.topic,
        "payload"  => { "status" => "ok", "response" => {} },
        "ref"      => join_ref,
        "join_ref" => join_ref
      )
      expect(channel).to be_joined

      socket.reset_sent_frames
      channel.rejoin
      expect(channel).to be_joining
      rejoin_frame = socket.last_sent_frame
      expect(rejoin_frame["event"]).to eq("phx_join")
      expect(rejoin_frame["payload"]["config"]["postgres_changes"]).to eq(
        [{ "event" => "INSERT", "schema" => "public", "table" => "items" }]
      )
    end
  end
end
