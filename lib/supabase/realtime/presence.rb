# frozen_string_literal: true

module Supabase
  module Realtime
    # Tracks presence state for one channel and implements the Phoenix Presence
    # sync algorithm: presence_state replaces the local snapshot, presence_diff
    # applies joins/leaves on top of it.
    #
    # The algorithm mirrors phoenix.js's Presence.syncState / Presence.syncDiff so
    # callers porting from JS/Python see identical behavior.
    class Presence
      attr_reader :state

      def initialize
        @state = {}
        @on_sync_callbacks = []
        @on_join_callbacks = []
        @on_leave_callbacks = []
      end

      # The first presence_state message after joining sends the full state. Any
      # local metas we already have for a key but the server doesn't are emitted
      # as leaves; anything new is emitted as a join.
      def sync_state(new_state)
        joins  = {}
        leaves = {}

        @state.each do |key, presence|
          leaves[key] = presence unless new_state.key?(key)
        end

        new_state.each do |key, new_presence|
          current = @state[key]
          if current
            joined = []
            left   = []
            current_refs = metas(current).map { |m| m["phx_ref"] }
            new_refs     = metas(new_presence).map { |m| m["phx_ref"] }
            joined = metas(new_presence).reject { |m| current_refs.include?(m["phx_ref"]) }
            left   = metas(current).reject     { |m| new_refs.include?(m["phx_ref"]) }
            joins[key]  = { "metas" => joined } unless joined.empty?
            leaves[key] = { "metas" => left }   unless left.empty?
          else
            joins[key] = new_presence
          end
        end

        @state = deep_copy(new_state)
        emit_joins(joins)
        emit_leaves(leaves)
        @on_sync_callbacks.each(&:call)
        @state
      end

      # Subsequent presence_diff messages carry only joins/leaves to apply.
      def sync_diff(diff)
        joins  = diff["joins"]  || {}
        leaves = diff["leaves"] || {}

        joins.each do |key, presence|
          if @state[key]
            existing_refs = metas(@state[key]).map { |m| m["phx_ref"] }
            new_metas     = metas(presence).reject { |m| existing_refs.include?(m["phx_ref"]) }
            @state[key]   = { "metas" => metas(@state[key]) + new_metas }
          else
            @state[key] = presence
          end
        end

        leaves.each do |key, presence|
          next unless @state[key]

          leaving_refs   = metas(presence).map { |m| m["phx_ref"] }
          remaining      = metas(@state[key]).reject { |m| leaving_refs.include?(m["phx_ref"]) }
          if remaining.empty?
            @state.delete(key)
          else
            @state[key] = { "metas" => remaining }
          end
        end

        emit_joins(joins)
        emit_leaves(leaves)
        @on_sync_callbacks.each(&:call)
        @state
      end

      # List every meta currently tracked, flat. Useful when callers don't care
      # about the per-key grouping.
      def list
        @state.values.flat_map { |presence| metas(presence) }
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

      private

      def metas(presence)
        Array(presence && presence["metas"])
      end

      def emit_joins(joins)
        joins.each do |key, presence|
          @on_join_callbacks.each { |cb| cb.call(key, presence) }
        end
      end

      def emit_leaves(leaves)
        leaves.each do |key, presence|
          @on_leave_callbacks.each { |cb| cb.call(key, presence) }
        end
      end

      def deep_copy(obj)
        Marshal.load(Marshal.dump(obj))
      end
    end
  end
end
