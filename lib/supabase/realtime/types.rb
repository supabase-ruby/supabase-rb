# frozen_string_literal: true

module Supabase
  module Realtime
    module Types
      # Phoenix protocol version this client speaks. Matches supabase-py.
      VSN = "1.0.0"

      DEFAULT_TIMEOUT_SECONDS = 10
      DEFAULT_HEARTBEAT_INTERVAL_SECONDS = 25

      # The special topic the Phoenix server uses for heartbeats and connection-level
      # control messages.
      PHOENIX_TOPIC = "phoenix"

      # Phoenix event names — mirror supabase-py's ChannelEvents enum 1:1 so docs
      # and message dumps line up.
      module ChannelEvents
        CLOSE            = "phx_close"
        ERROR            = "phx_error"
        JOIN             = "phx_join"
        REPLY            = "phx_reply"
        LEAVE            = "phx_leave"
        HEARTBEAT        = "heartbeat"
        ACCESS_TOKEN     = "access_token"
        BROADCAST        = "broadcast"
        PRESENCE         = "presence"
        PRESENCE_STATE   = "presence_state"
        PRESENCE_DIFF    = "presence_diff"
        SYSTEM           = "system"
        POSTGRES_CHANGES = "postgres_changes"
      end

      # Channel lifecycle states.
      module ChannelStates
        CLOSED  = :closed
        ERRORED = :errored
        JOINED  = :joined
        JOINING = :joining
        LEAVING = :leaving
        ALL = [CLOSED, ERRORED, JOINED, JOINING, LEAVING].freeze
      end

      # States passed to Channel#subscribe's callback so callers know whether the
      # join succeeded.
      module SubscribeStates
        SUBSCRIBED    = "SUBSCRIBED"
        TIMED_OUT     = "TIMED_OUT"
        CLOSED        = "CLOSED"
        CHANNEL_ERROR = "CHANNEL_ERROR"
      end

      # Server replies to a phx_join push with one of these statuses.
      module AckStatus
        OK      = "ok"
        ERROR   = "error"
        TIMEOUT = "timeout"
      end

      # Postgres-change event filters callers pass to Channel#on_postgres_changes.
      # "*" subscribes to all three events.
      module PostgresChangesEvent
        ALL    = "*"
        INSERT = "INSERT"
        UPDATE = "UPDATE"
        DELETE = "DELETE"
      end
    end
  end
end
