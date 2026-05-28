# frozen_string_literal: true

module Supabase
  module Postgrest
    module Types
      module CountMethod
        EXACT = "exact"
        PLANNED = "planned"
        ESTIMATED = "estimated"
        ALL = [EXACT, PLANNED, ESTIMATED].freeze
      end

      module ReturnMethod
        MINIMAL = "minimal"
        REPRESENTATION = "representation"
      end

      module RequestMethod
        GET = "GET"
        POST = "POST"
        PATCH = "PATCH"
        PUT = "PUT"
        DELETE = "DELETE"
        HEAD = "HEAD"
      end

      # PostgREST filter operators. Names mirror supabase-py's Filters enum 1:1
      # — see postgrest-py/src/postgrest/types.py.
      module Filters
        NOT = "not"
        EQ = "eq"
        NEQ = "neq"
        GT = "gt"
        GTE = "gte"
        LT = "lt"
        LTE = "lte"
        IS = "is"
        LIKE = "like"
        LIKE_ALL = "like(all)"
        LIKE_ANY = "like(any)"
        ILIKE = "ilike"
        ILIKE_ALL = "ilike(all)"
        ILIKE_ANY = "ilike(any)"
        FTS = "fts"
        PLFTS = "plfts"
        PHFTS = "phfts"
        WFTS = "wfts"
        IN = "in"
        CS = "cs"
        CD = "cd"
        OV = "ov"
        SL = "sl"
        SR = "sr"
        NXL = "nxl"
        NXR = "nxr"
        ADJ = "adj"
      end
    end
  end
end
