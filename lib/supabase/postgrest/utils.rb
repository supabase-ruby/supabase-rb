# frozen_string_literal: true

module Supabase
  module Postgrest
    module Utils
      module_function

      RESERVED_CHARS = ",:()"

      # Quote values that contain PostgREST reserved characters so they aren't
      # interpreted as operator separators. Mirrors supabase-py's sanitize_param.
      def sanitize_param(param)
        s = param.to_s
        return %("#{s}") if s.chars.any? { |c| RESERVED_CHARS.include?(c) }

        s
      end

      def sanitize_pattern_param(pattern)
        sanitize_param(pattern.to_s.gsub("%", "*"))
      end
    end
  end
end
