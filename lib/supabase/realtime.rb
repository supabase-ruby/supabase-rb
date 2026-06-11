# frozen_string_literal: true

require_relative "realtime/version"
require_relative "realtime/errors"
require_relative "realtime/types"
require_relative "realtime/transformers"
require_relative "realtime/callback_safety"
require_relative "realtime/message"
require_relative "realtime/presence"
require_relative "realtime/push"
require_relative "realtime/timer"
require_relative "realtime/socket"
require_relative "realtime/channel"
require_relative "realtime/client"

module Supabase
  module Realtime
  end
end
