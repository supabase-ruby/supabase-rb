# frozen_string_literal: true

module Supabase
  module Realtime
    # Reschedulable timer with caller-controlled backoff. Ports supabase-py's
    # AsyncTimer to Ruby threads: each `schedule_timeout` cancels the previous
    # tick and schedules a fresh one after `backoff.call(tries)` seconds. When
    # the tick fires, `tries` increments and `callback` runs — so successive
    # back-to-back ticks consume the backoff curve in order (1, 2, 4 ... for
    # `2**tries`). `reset` cancels any pending tick and zeroes the counter.
    #
    # Used by Realtime's reconnect/rejoin loops to apply exponential backoff
    # without re-implementing thread bookkeeping at every call site.
    class Timer
      attr_reader :tries

      # @param callback [#call] invoked after each successful tick.
      # @param backoff  [#call] receives the current `tries` (0-indexed) and
      #   returns the delay in seconds for the next tick.
      def initialize(callback:, backoff:)
        @callback = callback
        @backoff  = backoff
        @tries    = 0
        @thread   = nil
        @mutex    = Mutex.new
      end

      # Cancel any pending tick and schedule a new one. The next tick fires
      # after `backoff.call(current_tries)` seconds; once it fires `tries`
      # increments and `callback` runs.
      def schedule_timeout
        delay = nil
        @mutex.synchronize do
          kill_thread
          delay = @backoff.call(@tries)
          @thread = Thread.new do
            Thread.current.report_on_exception = false
            sleep(delay)
            @tries += 1
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
