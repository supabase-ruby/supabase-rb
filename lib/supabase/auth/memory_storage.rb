# frozen_string_literal: true

module Supabase
  module Auth
    class MemoryStorage < SupportedStorage
      attr_reader :storage

      def initialize
        @storage = {}
      end

      def get_item(key)
        @storage[key]
      end

      def set_item(key, value)
        @storage[key] = value
      end

      def remove_item(key)
        @storage.delete(key)
      end
    end
  end
end
