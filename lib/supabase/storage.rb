# frozen_string_literal: true

require_relative "storage/version"
require_relative "storage/errors"
require_relative "storage/types"
require_relative "storage/utils"
require_relative "storage/request"
require_relative "storage/bucket_api"
require_relative "storage/file_api"
require_relative "storage/analytics"
require_relative "storage/vectors"
require_relative "storage/client"

module Supabase
  module Storage
  end
end
