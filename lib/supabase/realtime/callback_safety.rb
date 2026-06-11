# frozen_string_literal: true

module Supabase
  module Realtime
    # Helper for invoking user-supplied callbacks (channel/presence/push hooks)
    # from the read-thread without letting a bad block tear down dispatch.
    #
    # supabase-py uses Python's exception-on-task semantics where one task's
    # exception doesn't kill the listener (`realtime/_async/client.py:113-117`
    # catches at the validation step; user-callback exceptions surface through
    # `asyncio` task results). The rb port runs callbacks on the websocket-gem
    # read-thread synchronously, so an unguarded exception kills the loop and
    # silently stops delivery to *every* channel on the client. This helper
    # rescues `StandardError`, logs a `warn` with the event name and the
    # exception class/message, and lets the read-thread continue.
    #
    # @see US-002 acceptance criteria — "колбэк, бросающий исключение, не мешает
    #   доставке следующего сообщения" / "исключение в колбэке одного канала не
    #   мешает доставке сообщений в соседний".
    module CallbackSafety
      module_function

      # Invoke `block` and swallow any `StandardError`, logging it via `logger`
      # at `warn` level. When `logger` is nil or doesn't respond to `warn`,
      # falls back to `Kernel#warn` ($stderr) so an unconfigured client still
      # leaves a trace instead of failing silently.
      def safe(logger, event_name)
        yield
      rescue StandardError => e
        msg = "[Supabase::Realtime] callback for '#{event_name}' raised " \
              "#{e.class}: #{e.message}"
        if logger.respond_to?(:warn)
          logger.warn(msg)
        else
          Kernel.warn(msg)
        end
        nil
      end
    end
  end
end
