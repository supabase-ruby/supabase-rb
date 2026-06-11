# frozen_string_literal: true

require_relative "callback_safety"

module Supabase
  module Realtime
    # Tracks presence state for one channel and implements the Phoenix Presence
    # sync algorithm. Mirrors supabase-py's AsyncRealtimePresence: raw
    # `{ key => { "metas" => [{ "phx_ref" => ..., ... }] } }` wire payloads are
    # transformed to a flat `{ key => [{ "presence_ref" => ..., ... }, ...] }`
    # shape before being stored or emitted, so listener callbacks receive
    # `(key, current_presences, new_presences)` with `presence_ref` keys.
    class Presence
      def initialize(logger: nil)
        @state = {}
        # Guards every read/write of @state so a reader thread iterating over
        # `presence_state` cannot collide with the realtime read-thread
        # applying inbound presence_state / presence_diff frames. US-007 stress
        # spec demonstrates the bare-Hash version raises "can't add a new key
        # into hash during iteration" under load; with the mutex + snapshot
        # accessor the same scenario stays clean. Callbacks are fanned out
        # AFTER the mutex is released to avoid user code reentering `state`
        # under the same lock.
        @mutex = Mutex.new
        @on_sync_callbacks = []
        @on_join_callbacks = []
        @on_leave_callbacks = []
        @logger = logger
      end

      # Snapshot of the current presence state. Returns a shallow dup of the
      # internal hash so callers can iterate safely while the read-thread
      # continues to apply inbound diffs (US-007 thread safety AC).
      def state
        @mutex.synchronize { @state.dup }
      end

      # First snapshot after joining: diff against the (possibly empty) local
      # state and apply the joins/leaves through the same code path as
      # `sync_diff`.
      def sync_state(raw_state)
        events = nil
        @mutex.synchronize do
          new_state = self.class.transform_state(raw_state)
          joins = {}
          leaves = @state.reject { |k, _| new_state.key?(k) }

          new_state.each do |key, presences|
            current = @state[key] || []

            if current.any?
              current_refs = current.map { |p| p["presence_ref"] }
              new_refs = presences.map { |p| p["presence_ref"] }
              joined_presences = presences.reject { |p| current_refs.include?(p["presence_ref"]) }
              left_presences = current.reject { |p| new_refs.include?(p["presence_ref"]) }
              joins[key] = joined_presences if joined_presences.any?
              leaves[key] = left_presences if left_presences.any?
            else
              joins[key] = presences
            end
          end

          events = apply_sync_diff_locked(joins, leaves)
        end
        fire_events(events)
        fire_sync_callbacks
        state
      end

      # Subsequent presence_diff messages: apply joins/leaves to the local state.
      # Raw input is transformed before being applied.
      def sync_diff(raw_diff)
        events = nil
        @mutex.synchronize do
          joins = self.class.transform_state(raw_diff["joins"] || {})
          leaves = self.class.transform_state(raw_diff["leaves"] || {})
          events = apply_sync_diff_locked(joins, leaves)
        end
        fire_events(events)
        fire_sync_callbacks
        state
      end

      # Flat list of every presence currently tracked.
      def list
        @mutex.synchronize { @state.values.flatten }
      end

      def on_sync(&block)
        @on_sync_callbacks << block
        self
      end

      def on_join(&block)
        @on_join_callbacks << block
        self
      end

      def on_leave(&block)
        @on_leave_callbacks << block
        self
      end

      def any_callbacks?
        [@on_sync_callbacks, @on_join_callbacks, @on_leave_callbacks].any? { |list| !list.empty? }
      end

      # Convert raw Phoenix wire format `{ key => { "metas" => [{phx_ref, ...}] } }`
      # to flat `{ key => [{presence_ref, ...}, ...] }`. Idempotent on already
      # transformed input.
      def self.transform_state(state)
        new_state = {}
        (state || {}).each do |key, presences|
          new_state[key] = if presences.is_a?(Hash) && presences.key?("metas")
                             presences["metas"].map { |meta| transform_meta(meta) }
                           else
                             Array(presences).map { |meta| transform_meta(meta) }
                           end
        end
        new_state
      end

      def self.transform_meta(meta)
        meta = meta.dup
        meta.delete("phx_ref_prev")
        if meta.key?("phx_ref")
          ref = meta.delete("phx_ref")
          { "presence_ref" => ref }.merge(meta)
        else
          meta
        end
      end

      private

      # Mutates @state and returns the join/leave events that should be fanned
      # out to user callbacks after the mutex is released. Order matches the
      # py reference (`AsyncRealtimePresence._sync_diff`): joins applied first,
      # then leaves; for leaves, the key is removed from @state once empty so
      # the next sync sees it as gone.
      def apply_sync_diff_locked(joins, leaves)
        events = []

        joins.each do |key, new_presences|
          current_presences = @state[key] || []
          @state[key] = new_presences

          if current_presences.any?
            joined_refs = new_presences.map { |p| p["presence_ref"] }
            keep_from_current = current_presences.reject { |p| joined_refs.include?(p["presence_ref"]) }
            @state[key] = keep_from_current + @state[key]
          end

          events << [:join, key, current_presences, new_presences]
        end

        leaves.each do |key, left_presences|
          current_presences = @state[key] || []
          next if current_presences.empty?

          remove_refs = left_presences.map { |p| p["presence_ref"] }
          remaining = current_presences.reject { |p| remove_refs.include?(p["presence_ref"]) }
          @state[key] = remaining

          events << [:leave, key, remaining, left_presences]

          @state.delete(key) if remaining.empty?
        end

        events
      end

      def fire_events(events)
        events.each do |kind, key, current_or_remaining, new_or_left|
          callbacks = kind == :join ? @on_join_callbacks : @on_leave_callbacks
          label     = kind == :join ? "presence_join" : "presence_leave"
          callbacks.each do |cb|
            CallbackSafety.safe(@logger, label) do
              cb.call(key, current_or_remaining, new_or_left)
            end
          end
        end
      end

      def fire_sync_callbacks
        @on_sync_callbacks.each do |cb|
          CallbackSafety.safe(@logger, "presence_sync") { cb.call }
        end
      end
    end
  end
end
