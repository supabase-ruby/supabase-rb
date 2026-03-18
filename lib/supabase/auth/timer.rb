# frozen_string_literal: true

module Supabase
  module Auth
    class Timer
      # @param interval [Float] delay in seconds before firing the callback
      # @param block [Proc] the callback to execute after the delay
      def initialize(interval, &block)
        @interval = interval
        @block = block
        @thread = nil
      end

      def start
        @thread = Thread.new do
          sleep @interval
          @block.call
        rescue StandardError
          # Swallow errors in timer thread (matches Python daemon thread behavior)
        end
        @thread
      end

      def cancel
        if @thread
          @thread.kill
          @thread = nil
        end
      end

      def alive?
        @thread&.alive? || false
      end
    end
  end
end
