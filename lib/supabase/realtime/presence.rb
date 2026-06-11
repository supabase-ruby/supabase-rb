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
      attr_reader :state

      def initialize(logger: nil)
        @state = {}
        @on_sync_callbacks = []
        @on_join_callbacks = []
        @on_leave_callbacks = []
        @logger = logger
      end

      # First snapshot after joining: diff against the (possibly empty) local
      # state and apply the joins/leaves through the same code path as
      # `sync_diff`.
      def sync_state(raw_state)
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

        sync_diff_internal(joins, leaves)
        fire_sync_callbacks
        @state
      end

      # Subsequent presence_diff messages: apply joins/leaves to the local state.
      # Raw input is transformed before being applied.
      def sync_diff(raw_diff)
        joins = self.class.transform_state(raw_diff["joins"] || {})
        leaves = self.class.transform_state(raw_diff["leaves"] || {})
        sync_diff_internal(joins, leaves)
        fire_sync_callbacks
        @state
      end

      # Flat list of every presence currently tracked.
      def list
        @state.values.flatten
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

      def sync_diff_internal(joins, leaves)
        joins.each do |key, new_presences|
          current_presences = @state[key] || []
          @state[key] = new_presences

          if current_presences.any?
            joined_refs = new_presences.map { |p| p["presence_ref"] }
            keep_from_current = current_presences.reject { |p| joined_refs.include?(p["presence_ref"]) }
            @state[key] = keep_from_current + @state[key]
          end

          @on_join_callbacks.each do |cb|
            CallbackSafety.safe(@logger, "presence_join") do
              cb.call(key, current_presences, new_presences)
            end
          end
        end

        leaves.each do |key, left_presences|
          current_presences = @state[key] || []
          next if current_presences.empty?

          remove_refs = left_presences.map { |p| p["presence_ref"] }
          remaining = current_presences.reject { |p| remove_refs.include?(p["presence_ref"]) }
          @state[key] = remaining

          @on_leave_callbacks.each do |cb|
            CallbackSafety.safe(@logger, "presence_leave") do
              cb.call(key, remaining, left_presences)
            end
          end

          @state.delete(key) if remaining.empty?
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
