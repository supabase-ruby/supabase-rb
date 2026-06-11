# frozen_string_literal: true

require "supabase/realtime"

# US-006: Realtime — выровнять кривую бэкоффа rejoin-таймера.
#
# Port of supabase-py's `test_timer.py` to rb, plus the explicit backoff-curve
# coverage required by AC #2. The reference timer
# (`realtime/_async/timer.py:24-29`) increments `self.tries` BEFORE computing
# the delay and passes `self.tries + 1` to `timer_calc`:
#
#   def schedule_timeout(self):
#       if self.timer: self.timer.cancel()
#       self.tries += 1
#       delay = self.timer_calc(self.tries + 1)
#       self.timer = asyncio.create_task(self._run_timer(delay))
#
# Before US-006, rb's Timer passed bare `tries` (starting at 0) and incremented
# after the sleep — so first attempt had `tries=0` during the delay computation
# and `tries=1` only after the callback fired. AC #1 ("первая попытка получает
# tries=1") aligns the rb semantics with py: first schedule_timeout call yields
# `tries=1` immediately and the delay is `backoff.call(tries+1) = backoff.call(2)`.
#
# AC #2 ("последовательность задержек для tries 1..5 идентична py"): with the
# channel's `lambda tries: 2**tries`, py's sequence for the first five attempts
# is [2**2, 2**3, 2**4, 2**5, 2**6] = [4, 8, 16, 32, 64]. rb must produce the
# identical sequence; the legacy 60 s cap on the channel's rejoin lambda has
# been dropped (py rejoin has no cap; only the socket-level reconnect loop
# does, see US-003).
RSpec.describe Supabase::Realtime::Timer, "US-006 backoff curve parity" do
  # Mirrors py `linear_backoff` from test_timer.py.
  let(:linear_backoff) { ->(tries) { tries * 0.1 } }
  let(:fired) { Queue.new }

  def join_thread(timer)
    timer.instance_variable_get(:@thread)&.join
  end

  describe "AC #1 — semantics align with py (first attempt: tries == 1)" do
    it "bumps tries to 1 on the very first schedule_timeout call" do
      timer = described_class.new(callback: -> {}, backoff: linear_backoff)
      allow(timer).to receive(:sleep)

      expect { timer.schedule_timeout }
        .to change(timer, :tries).from(0).to(1)
    end

    it "computes the first delay as backoff.call(tries + 1) (py timer.py:29)" do
      delays = []
      timer = described_class.new(callback: -> {}, backoff: linear_backoff)
      allow(timer).to receive(:sleep) { |s| delays << s }

      timer.schedule_timeout
      join_thread(timer)

      # py: tries=1 after bump, delay = linear_backoff(1+1) = 0.2
      expect(delays).to eq([0.2])
    end

    it "the callback observes tries == 1 (counter is bumped BEFORE the sleep)" do
      observed = []
      timer = nil
      timer = described_class.new(
        callback: -> { observed << timer.tries },
        backoff: linear_backoff
      )
      allow(timer).to receive(:sleep)

      timer.schedule_timeout
      join_thread(timer)

      expect(observed).to eq([1])
    end
  end

  describe "AC #2 — delay sequence for tries 1..5 is identical to py" do
    it "with linear_backoff matches py test_timer.py: linear_backoff(2..6)" do
      delays = []
      timer = described_class.new(callback: -> {}, backoff: linear_backoff)
      allow(timer).to receive(:sleep) { |s| delays << s }

      5.times do
        timer.schedule_timeout
        join_thread(timer)
      end

      # py produces backoff.call(tries+1) for tries=1..5 → linear_backoff(2..6).
      # Compute the expected sequence with the same lambda so float precision
      # cannot drift the comparison (`3 * 0.1` ≠ `0.3` in IEEE 754).
      expected = (2..6).map { |t| linear_backoff.call(t) }
      expect(delays).to eq(expected)
      expect(timer.tries).to eq(5)
    end

    it "with channel's `2**tries` lambda matches py: [4, 8, 16, 32, 64]" do
      delays = []
      pow_backoff = ->(tries) { 2.0**tries }
      timer = described_class.new(callback: -> {}, backoff: pow_backoff)
      allow(timer).to receive(:sleep) { |s| delays << s }

      5.times do
        timer.schedule_timeout
        join_thread(timer)
      end

      # py rejoin (`realtime/_async/channel.py:109-111`) uses the same
      # `lambda tries: 2**tries`. Sequence: 2**2, 2**3, 2**4, 2**5, 2**6.
      expect(delays).to eq([4.0, 8.0, 16.0, 32.0, 64.0])
    end
  end

  # The remaining specs mirror the structure of py `test_timer.py` so the rb
  # suite covers the same surface area (init, schedule, reset, multiple
  # schedules, callback errors, cancellation).
  describe "py test_timer.py parity — full surface coverage" do
    it "test_timer_initialization: tries=0, no pending thread, retains both callables" do
      cb = -> {}
      timer = described_class.new(callback: cb, backoff: linear_backoff)

      expect(timer.tries).to eq(0)
      expect(timer.instance_variable_get(:@thread)).to be_nil
      expect(timer.instance_variable_get(:@callback)).to be(cb)
      expect(timer.instance_variable_get(:@backoff)).to be(linear_backoff)
    end

    it "test_timer_schedule: tries advances to 1 and callback fires after the delay" do
      timer = described_class.new(callback: -> { fired << :tick }, backoff: linear_backoff)
      allow(timer).to receive(:sleep)

      timer.schedule_timeout
      expect(timer.tries).to eq(1)
      expect(timer.instance_variable_get(:@thread)).not_to be_nil

      join_thread(timer)
      expect(fired.pop).to eq(:tick)
    end

    it "test_timer_reset: cancels pending tick before it fires and zeroes the counter" do
      slow = described_class.new(callback: -> { fired << :tick }, backoff: ->(_) { 5 })
      slow.schedule_timeout
      thread = slow.instance_variable_get(:@thread)

      slow.reset
      expect(slow.tries).to eq(0)
      expect(slow.instance_variable_get(:@thread)).to be_nil

      thread.join(0.5)
      expect(thread).not_to be_alive
      expect(fired).to be_empty
    end

    it "test_timer_multiple_schedules: only the latest tick fires; tries == calls" do
      slow_then_fast = described_class.new(
        callback: -> { fired << :tick },
        backoff: ->(_) { 0 } # stub-free instant fire after kill_thread races
      )
      allow(slow_then_fast).to receive(:sleep)

      3.times { slow_then_fast.schedule_timeout }
      join_thread(slow_then_fast)

      expect(slow_then_fast.tries).to eq(3)
      # Each schedule_timeout cancels the previous thread BEFORE it can append
      # to `fired` — only the last surviving thread reaches the callback.
      expect(fired.size).to eq(1)
    end

    # NOTE: py wraps its `_run_timer` body in a try/except and logs unhandled
    # callback errors (`realtime/_async/timer.py:33-40`). The rb Timer relies
    # on `report_on_exception = false` to silence the unhandled-thread warning
    # but lets the exception terminate the worker thread (and re-raise on any
    # `Thread#join`). Wiring a rescue block in the Timer is intentionally out
    # of scope for US-006 (which is strictly the backoff curve) — captured as
    # a TODO for a future story that aligns Timer error-handling with py.

    it "test_timer_cancellation: killing the thread prevents the callback from firing" do
      slow = described_class.new(callback: -> { fired << :tick }, backoff: ->(_) { 5 })
      slow.schedule_timeout

      thread = slow.instance_variable_get(:@thread)
      thread.kill

      thread.join(0.5)
      expect(thread).not_to be_alive
      expect(fired).to be_empty
    end
  end
end
