# frozen_string_literal: true

require "json"

require_relative "errors"

module Supabase
  module Realtime
    # A Phoenix Channel frame: { event, topic, payload, ref, join_ref }.
    # Used both for outbound pushes and parsed inbound messages.
    Message = Struct.new(:event, :topic, :payload, :ref, :join_ref, keyword_init: true) do
      def to_json(*)
        JSON.generate(
          "event"    => event,
          "topic"    => topic,
          "payload"  => payload,
          "ref"      => ref,
          "join_ref" => join_ref
        )
      end

      # Parse a raw JSON frame received on the WebSocket into a Message. Returns
      # nil (and logs a warning) when the frame isn't well-formed JSON — the
      # caller (read-loop in {Client#handle_inbound}) treats nil as "skip this
      # frame" so a single garbled byte sequence can't kill the loop. Closes
      # US-017 / F-C-minor: previously raised ProtocolError and propagated up
      # into the socket adapter, taking down the read thread on first bad frame.
      def self.parse(raw)
        json = JSON.parse(raw)
        new(
          event:    json["event"],
          topic:    json["topic"],
          payload:  json["payload"] || {},
          ref:      json["ref"],
          join_ref: json["join_ref"]
        )
      rescue JSON::ParserError => e
        msg = "[Supabase::Realtime] Skipping malformed Phoenix frame: #{e.message}"
        if defined?(@logger) && @logger.respond_to?(:warn)
          @logger.warn(msg)
        else
          warn(msg)
        end
        nil
      end
    end
  end
end
