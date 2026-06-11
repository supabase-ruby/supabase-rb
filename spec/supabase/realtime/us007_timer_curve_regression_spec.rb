# frozen_string_literal: true

require "supabase/realtime"

# US-007: AC #2 — "Тест таймера фиксирует кривую из US-006".
#
# US-006 уже зафиксировал кривую напрямую через `Timer` (см.
# `us006_timer_backoff_curve_spec.rb`). Эта спека добавляет regression-уровень
# повыше: при N подряд errored-join'ах канал должен ставить rejoin_timer на
# именно ту последовательность задержек, что описана py
# (`realtime/_async/channel.py:109-111`): `2**(tries+1)` для каждой попытки,
# без 60-секундного кэпа. Если кто-то снова навесит кэп на rejoin-лямбду
# канала (как было до US-006), эта спека покажет, что пятая попытка получает
# 64 с, а не 60 с.
#
# Эталон py: `realtime/_async/timer.py:24-29` + `channel.py:109-111`.
RSpec.describe "US-007: timer curve regression (locked in from US-006)" do
  let(:socket) { Supabase::Realtime::TestSocket.new }
  let(:client) do
    Supabase::Realtime::Client.new(
      url: "wss://x/v1",
      socket: socket,
      heartbeat_interval: 0,
      auto_reconnect: false
    )
  end

  it "rejoin_timer for a fresh channel produces the py curve [4, 8, 16, 32, 64] for tries 1..5" do
    channel = client.channel("public:room")
    rejoin_timer = channel.rejoin_timer

    delays = []
    allow(rejoin_timer).to receive(:sleep) { |s| delays << s }

    5.times do
      rejoin_timer.schedule_timeout
      rejoin_timer.instance_variable_get(:@thread)&.join
    end

    # py rejoin lambda is `lambda tries: 2**tries`, Timer hands it `tries+1`.
    # So the curve is 2**2, 2**3, 2**4, 2**5, 2**6 — no 60s cap.
    expect(delays).to eq([4.0, 8.0, 16.0, 32.0, 64.0])
    expect(rejoin_timer.tries).to eq(5)
  end

  it "after a successful on_join_ok, rejoin_timer.reset zeroes the curve back to tries=0" do
    channel = client.channel("public:room")
    rejoin_timer = channel.rejoin_timer
    allow(rejoin_timer).to receive(:sleep)

    3.times do
      rejoin_timer.schedule_timeout
      rejoin_timer.instance_variable_get(:@thread)&.join
    end
    expect(rejoin_timer.tries).to eq(3)

    # The channel resets the rejoin timer once the server acks a successful
    # join (`channel.rb#on_join_ok` line 455). Simulate that direct path.
    rejoin_timer.reset
    expect(rejoin_timer.tries).to eq(0)

    delays = []
    allow(rejoin_timer).to receive(:sleep) { |s| delays << s }
    rejoin_timer.schedule_timeout
    rejoin_timer.instance_variable_get(:@thread)&.join

    # First delay after reset: 2**(1+1) = 4 s — identical to a brand-new timer.
    expect(delays).to eq([4.0])
  end
end
