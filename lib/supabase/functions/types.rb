# frozen_string_literal: true

module Supabase
  module Functions
    module Types
      # Returned by Client#invoke. `data` is parsed JSON when response_type: :json
      # (or auto-detected from a JSON Content-Type), otherwise the raw response body.
      Response = Struct.new(:data, :status, :headers, keyword_init: true)

      # Supabase Edge Function regions. Use FunctionRegion::US_EAST_1 etc., or pass
      # the bare string ("us-east-1") to Client#invoke — both are accepted.
      module FunctionRegion
        ANY              = "any"
        AP_NORTHEAST_1   = "ap-northeast-1"
        AP_NORTHEAST_2   = "ap-northeast-2"
        AP_SOUTH_1       = "ap-south-1"
        AP_SOUTHEAST_1   = "ap-southeast-1"
        AP_SOUTHEAST_2   = "ap-southeast-2"
        CA_CENTRAL_1     = "ca-central-1"
        EU_CENTRAL_1     = "eu-central-1"
        EU_WEST_1        = "eu-west-1"
        EU_WEST_2        = "eu-west-2"
        EU_WEST_3        = "eu-west-3"
        SA_EAST_1        = "sa-east-1"
        US_EAST_1        = "us-east-1"
        US_WEST_1        = "us-west-1"
        US_WEST_2        = "us-west-2"

        ALL = [
          ANY, AP_NORTHEAST_1, AP_NORTHEAST_2, AP_SOUTH_1, AP_SOUTHEAST_1, AP_SOUTHEAST_2,
          CA_CENTRAL_1, EU_CENTRAL_1, EU_WEST_1, EU_WEST_2, EU_WEST_3,
          SA_EAST_1, US_EAST_1, US_WEST_1, US_WEST_2
        ].freeze

        # PascalCase aliases mirroring supabase-py's FunctionRegion StrEnum, so
        # snippets ported from py (`FunctionRegion.UsEast1`) work without edits.
        Any            = ANY
        ApNortheast1   = AP_NORTHEAST_1
        ApNortheast2   = AP_NORTHEAST_2
        ApSouth1       = AP_SOUTH_1
        ApSoutheast1   = AP_SOUTHEAST_1
        ApSoutheast2   = AP_SOUTHEAST_2
        CaCentral1     = CA_CENTRAL_1
        EuCentral1     = EU_CENTRAL_1
        EuWest1        = EU_WEST_1
        EuWest2        = EU_WEST_2
        EuWest3        = EU_WEST_3
        SaEast1        = SA_EAST_1
        UsEast1        = US_EAST_1
        UsWest1        = US_WEST_1
        UsWest2        = US_WEST_2
      end
    end
  end
end
