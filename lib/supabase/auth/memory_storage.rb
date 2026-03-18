# frozen_string_literal: true

module Supabase
  module Auth
    class MemoryStorage
      def initialize
        @store = {}
      end

      def get_item(key)
        @store[key]
      end

      def set_item(key, value)
        @store[key] = value
      end

      def remove_item(key)
        @store.delete(key)
      end
    end
  end
end
