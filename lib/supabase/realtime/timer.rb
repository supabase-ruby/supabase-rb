# frozen_string_literal: true

module Supabase
  module Realtime
    # Reschedulable timer with caller-controlled backoff. Ports supabase-py's
    # AsyncTimer to Ruby threads (`realtime/_async/timer.py:24-29`): each
    # `schedule_timeout` cancels the previous tick, increments `tries`, and
    # schedules a fresh tick after `backoff.call(tries + 1)` seconds. So the
    # first call advances `tries` 0→1 and waits `backoff.call(2)`; the second
    # call advances `tries` 1→2 and waits `backoff.call(3)`; and so on. `reset`
    # cancels any pending tick and zeroes the counter.
    #
    # The `tries + 1` offset matches py 1:1 (US-006). For example, with the
    # channel's `lambda tries: 2**tries` the delay curve is 4, 8, 16, 32, 64 s
    # for the first five attempts — identical to py's rejoin timer.
    #
    # Used by Realtime's reconnect/rejoin loops to apply exponential backoff
    # without re-implementing thread bookkeeping at every call site.
    class Timer
      attr_reader :tries

      # @param callback [#call] invoked after each successful tick.
      # @param backoff  [#call] receives `tries + 1` (1-indexed at first call)
      #   and returns the delay in seconds for the next tick. Matches py's
      #   `timer_calc(self.tries + 1)` contract.
      def initialize(callback:, backoff:)
        @callback = callback
        @backoff  = backoff
        @tries    = 0
        @thread   = nil
        @mutex    = Mutex.new
      end

      # Cancel any pending tick and schedule a new one. Mirrors py
      # (`timer.py:24-29`): bump `tries` first, then sleep for
      # `backoff.call(tries + 1)` seconds before invoking `callback`. On the
      # first call this yields `tries = 1` BEFORE the sleep, so by the time
      # the callback fires the counter already reflects the attempt number.
      def schedule_timeout
        delay = nil
        @mutex.synchronize do
          kill_thread
          @tries += 1
          delay = @backoff.call(@tries + 1)
          @thread = Thread.new do
            Thread.current.report_on_exception = false
            sleep(delay)
            @callback.call
          end
        end
        self
      end

      # Cancel the pending tick and reset the retry counter to zero. Idempotent.
      def reset
        @mutex.synchronize do
          kill_thread
          @tries = 0
        end
        self
      end

      private

      def kill_thread
        thread = @thread
        @thread = nil
        thread.kill if thread && thread != Thread.current
      end
    end
  end
end
