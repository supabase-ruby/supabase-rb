# frozen_string_literal: true

require_relative "socket"

module Supabase
  module Realtime
    # In-memory {Socket} implementation for specs and local prototyping. Captures
    # every frame the client sends in `sent_frames`, and exposes `inject(frame)`
    # so a test can simulate a server response.
    #
    # Not intended for production use — bring a real WebSocket adapter for that.
    class TestSocket
      include Socket

      attr_reader :sent_frames

      def initialize
        @connected   = false
        @sent_frames = []
      end

      def connect
        @connected = true
        open_callbacks.each(&:call)
      end

      def close
        @connected = false
        close_callbacks.each(&:call)
      end

      def send(payload)
        @sent_frames << payload
      end

      def connected?
        @connected
      end

      # ----- Test helpers -----

      # Push a JSON frame as if it came from the server. Accepts a JSON String
      # or a Hash (which gets JSON-encoded for you).
      def inject(frame)
        raw = frame.is_a?(String) ? frame : JSON.generate(frame)
        message_callbacks.each { |cb| cb.call(raw) }
      end

      # Convenience: the last frame the client pushed, parsed back to a Hash.
      def last_sent_frame
        return nil if @sent_frames.empty?

        JSON.parse(@sent_frames.last)
      end

      def sent_events
        @sent_frames.map { |f| JSON.parse(f)["event"] }
      end

      def reset_sent_frames
        @sent_frames = []
      end
    end
  end
end
