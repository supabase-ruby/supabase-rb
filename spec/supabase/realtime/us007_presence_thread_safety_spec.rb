# frozen_string_literal: true

require "supabase/realtime"
require "json"

# US-007 / AC #3 — стресс-спека на тред-безопасность `presence_state`:
# пока read-тред транспорта льёт presence_diff-фреймы в канал, пользовательский
# код должен иметь возможность читать `channel.presence_state` без падений
# вида `RuntimeError: can't add a new key into hash during iteration`.
#
# Это rb-специфичная история: py всё гоняет внутри одного asyncio-loop'а,
# поэтому конкурентного доступа не бывает. В rb realtime read-loop — это
# отдельный Thread (`Sockets::WebsocketClientSimple` поднимает его на on_open),
# а пользователь читает `presence_state` из своего треда (Rails, Sidekiq и т.п.).
#
# Защита: `Supabase::Realtime::Presence` теперь хранит `@state` под Mutex и
# в `#state` возвращает shallow-dup'ы — итерации поверх возвращённого хэша
# больше не пересекаются с тем хэшем, который пишет `sync_state`/`sync_diff`.
RSpec.describe "US-007: presence_state thread safety under load" do
  # ----- Low-level: Presence directly (deterministic, no socket) -----
  describe "Presence under concurrent writer / readers" do
    let(:presence) { Supabase::Realtime::Presence.new }

    def diff(joins: {}, leaves: {})
      transformer = lambda do |hash|
        hash.transform_values do |entries|
          { "metas" => entries.map { |e| { "phx_ref" => e[:ref], "user_id" => e[:user_id] } } }
        end
      end
      { "joins" => transformer.call(joins), "leaves" => transformer.call(leaves) }
    end

    it "concurrent reads of #state during a heavy sync_diff stream do not raise" do
      # Pre-warm: seed 50 keys so the reader has something non-trivial to walk.
      seed = (1..50).to_h { |i| ["k#{i}", [{ ref: "r#{i}_0", user_id: i.to_s }]] }
      presence.sync_diff(diff(joins: seed))

      iterations = 2_000
      stop = false
      reader_errors = Queue.new
      reads = 0

      readers = Array.new(4) do
        Thread.new do
          Thread.current.report_on_exception = false
          until stop
            begin
              # Iterate over the snapshot — keys, values, AND nested arrays.
              snapshot = presence.state
              snapshot.each do |_key, presences|
                presences.each { |p| p["presence_ref"] }
              end
              snapshot.values.flatten.each { |p| p["presence_ref"] }
              reads += 1
            rescue StandardError => e
              reader_errors << e
              break
            end
          end
        end
      end

      writer = Thread.new do
        Thread.current.report_on_exception = false
        iterations.times do |i|
          # Half the time add a new key, half the time replace an existing one,
          # and occasionally drop a key entirely. This is the same kind of churn
          # the server inflicts during heavy presence activity.
          op = i % 5
          case op
          when 0, 1
            presence.sync_diff(diff(joins: { "k#{i}" => [{ ref: "rN#{i}", user_id: i.to_s }] }))
          when 2
            presence.sync_diff(diff(joins: { "k#{i % 50 + 1}" => [{ ref: "rR#{i}", user_id: i.to_s }] }))
          when 3
            existing_key = "k#{i % 50 + 1}"
            cur = presence.state[existing_key] || []
            if cur.any?
              ref_to_leave = cur.first["presence_ref"]
              presence.sync_diff(diff(leaves: { existing_key => [{ ref: ref_to_leave, user_id: "x" }] }))
            end
          when 4
            presence.sync_state(diff(joins: { "snapshot_#{i}" => [{ ref: "rS#{i}", user_id: "s" }] })["joins"])
          end
        end
      end

      writer.join
      stop = true
      readers.each(&:join)

      expect(reader_errors).to be_empty, -> {
        errors = []
        errors << reader_errors.pop until reader_errors.empty?
        "reader thread raised: #{errors.map { |e| "#{e.class}: #{e.message}" }.join("; ")}"
      }
      # Sanity: readers actually ran (not just immediately stopped).
      expect(reads).to be > 0
    end

    it "snapshot returned by #state is decoupled from background writes" do
      presence.sync_diff(diff(joins: { "a" => [{ ref: "r_a", user_id: "u" }] }))
      snapshot = presence.state

      # Apply a burst of mutations — the snapshot the caller already grabbed
      # must not see them.
      100.times do |i|
        presence.sync_diff(diff(joins: { "k#{i}" => [{ ref: "r#{i}", user_id: i.to_s }] }))
      end
      presence.sync_diff(diff(leaves: { "a" => [{ ref: "r_a", user_id: "u" }] }))

      expect(snapshot.keys).to eq(["a"])
      expect(snapshot["a"].map { |p| p["presence_ref"] }).to eq(["r_a"])
      # Live state has moved on.
      expect(presence.state).not_to have_key("a")
      expect(presence.state.keys.size).to eq(100)
    end
  end

  # ----- High-level: full Channel + injected frames via TestSocket -----
  describe "channel.presence_state under simulated read-thread injection" do
    it "user-thread reads while injection-thread floods presence_diff frames stay clean" do
      socket = Supabase::Realtime::TestSocket.new
      client = Supabase::Realtime::Client.new(
        url: "wss://x/v1",
        socket: socket,
        heartbeat_interval: 0,
        auto_reconnect: false
      )
      client.connect
      channel = client.channel("public:room")
      channel.subscribe
      join_ref = JSON.parse(socket.sent_frames.last)["ref"]
      socket.inject(
        "event"    => "phx_reply",
        "topic"    => channel.topic,
        "payload"  => { "status" => "ok", "response" => {} },
        "ref"      => join_ref,
        "join_ref" => join_ref
      )

      # Seed with 30 presences so the reader has non-trivial content.
      seed_joins = (1..30).to_h do |i|
        ["k#{i}", { "metas" => [{ "phx_ref" => "seed_#{i}", "user_id" => i.to_s }] }]
      end
      socket.inject(
        "event"   => "presence_diff",
        "topic"   => channel.topic,
        "payload" => { "joins" => seed_joins, "leaves" => {} }
      )

      stop = false
      reader_errors = Queue.new
      reads = 0

      reader = Thread.new do
        Thread.current.report_on_exception = false
        until stop
          begin
            state = channel.presence_state
            state.each do |_k, presences|
              presences.each { |p| p["presence_ref"] }
            end
            reads += 1
          rescue StandardError => e
            reader_errors << e
            break
          end
        end
      end

      # Simulates the realtime adapter's read-thread pumping frames in.
      injector = Thread.new do
        Thread.current.report_on_exception = false
        500.times do |i|
          socket.inject(
            "event"   => "presence_diff",
            "topic"   => channel.topic,
            "payload" => {
              "joins"  => { "k#{i % 30 + 1}" => { "metas" => [{ "phx_ref" => "r_#{i}", "user_id" => i.to_s }] } },
              "leaves" => {}
            }
          )
        end
      end

      injector.join
      # Don't stop the reader before it has been scheduled at least once: on a
      # busy two-core CI runner the injector can burn through all 500 frames
      # before the reader thread ever runs, leaving `reads == 0` and flaking
      # the `reads > 0` assertion below.
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      while reads.zero? && reader_errors.empty? &&
            Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        sleep 0.005
      end
      stop = true
      reader.join

      expect(reader_errors).to be_empty, -> {
        errors = []
        errors << reader_errors.pop until reader_errors.empty?
        "reader raised: #{errors.map { |e| "#{e.class}: #{e.message}" }.join("; ")}"
      }
      expect(reads).to be > 0
      # State still consistent — all 30 keys still present (we only joined).
      final_state = channel.presence_state
      expect(final_state.keys.size).to eq(30)
    end
  end
end
