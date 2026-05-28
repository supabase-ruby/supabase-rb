# frozen_string_literal: true

require_relative "types"

module Supabase
  module Realtime
    # One outbound Phoenix push, awaiting a reply. The channel matches incoming
    # phx_reply messages to pushes by `ref` and fires the appropriate handler.
    #
    # `receive(:ok / :error / :timeout) { |payload| ... }` registers handlers
    # before the push is sent, mirroring phoenix.js's Push API.
    class Push
      attr_reader :ref, :event, :payload, :received_status

      def initialize(channel, event, payload = {}, ref: nil)
        @channel  = channel
        @event    = event
        @payload  = payload
        @ref      = ref
        @handlers = Hash.new { |h, k| h[k] = [] }
        @received_status = nil
        @received_payload = nil
      end

      def receive(status, &block)
        if @received_status == status
          # Reply already arrived before this handler was attached — fire immediately.
          block.call(@received_payload)
        else
          @handlers[status] << block
        end
        self
      end

      # Called by the Channel when a phx_reply with matching ref arrives.
      def resolve(status:, payload:)
        @received_status  = status
        @received_payload = payload
        @handlers[status].each { |h| h.call(payload) }
      end

      # Called by the Channel if no reply arrives within the timeout window.
      def time_out
        resolve(status: Types::AckStatus::TIMEOUT, payload: {})
      end
    end
  end
end
