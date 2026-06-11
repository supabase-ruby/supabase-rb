# frozen_string_literal: true

require_relative "callback_safety"
require_relative "types"

module Supabase
  module Realtime
    # One outbound Phoenix push, awaiting a reply. The channel matches incoming
    # phx_reply messages to pushes by `ref` and fires the appropriate handler.
    #
    # `receive(:ok / :error / :timeout) { |payload| ... }` registers handlers
    # before the push is sent, mirroring phoenix.js's Push API.
    #
    # Pushes can be given a timeout via `start_timeout(seconds)`; if no reply is
    # received within that window the push resolves with AckStatus::TIMEOUT and
    # is removed from the channel's pending_pushes registry.
    class Push
      attr_reader :ref, :event, :payload, :received_status

      def initialize(channel, event, payload = {}, ref: nil, timeout: Types::DEFAULT_TIMEOUT_SECONDS)
        @channel  = channel
        @event    = event
        @payload  = payload
        @ref      = ref
        @timeout  = timeout
        @handlers = Hash.new { |h, k| h[k] = [] }
        @received_status = nil
        @received_payload = nil
        @timeout_thread = nil
        @mutex = Mutex.new
      end

      def receive(status, &block)
        if @received_status == status
          # Reply already arrived before this handler was attached — fire immediately.
          CallbackSafety.safe(logger, "push_receive:#{status}") { block.call(@received_payload) }
        else
          @handlers[status] << block
        end
        self
      end

      # Called by the Channel when a phx_reply with matching ref arrives.
      def resolve(status:, payload:)
        @mutex.synchronize do
          # Idempotent: a late timeout firing after a real ack must not fire
          # callbacks twice. First resolution wins.
          return if @received_status

          @received_status  = status
          @received_payload = payload
        end
        cancel_timeout
        @handlers[status].each do |h|
          CallbackSafety.safe(logger, "push_receive:#{status}") { h.call(payload) }
        end
      end

      # Schedule a TIMEOUT resolution if no reply arrives within `seconds`.
      # Safe to call multiple times — only the first call schedules.
      def start_timeout(seconds = @timeout)
        @mutex.synchronize do
          return if @timeout_thread
          return if @received_status

          @timeout_thread = Thread.new do
            sleep(seconds)
            time_out
          end
        end
        self
      end

      # Called when no reply arrives in time, or as an explicit forced-timeout
      # entry point.
      def time_out
        resolve(status: Types::AckStatus::TIMEOUT, payload: {})
        # Pending registry lives on the channel — clean up so a late reply
        # doesn't reach a push we've already given up on.
        @channel.send(:remove_pending, @ref) if @channel.respond_to?(:remove_pending, true) && @ref
      end

      # Cancel the pending timeout (no-op if not started or already resolved).
      def cancel_timeout
        @mutex.synchronize do
          thread = @timeout_thread
          @timeout_thread = nil
          thread&.kill if thread && thread != Thread.current
        end
      end

      private

      def logger
        @channel.respond_to?(:logger) ? @channel.logger : nil
      end
    end
  end
end
