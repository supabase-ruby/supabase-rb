# frozen_string_literal: true

module Supabase
  module Auth
    class SupportedStorage
      def get_item(_key)
        raise NotImplementedError, "#{self.class}#get_item must be implemented"
      end

      def set_item(_key, _value)
        raise NotImplementedError, "#{self.class}#set_item must be implemented"
      end

      def remove_item(_key)
        raise NotImplementedError, "#{self.class}#remove_item must be implemented"
      end
    end
  end
end
