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

      # Parse a raw JSON frame received on the WebSocket into a Message. Raises
      # ProtocolError if the frame isn't well-formed JSON.
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
        raise Errors::ProtocolError, "Malformed Phoenix frame: #{e.message}"
      end
    end
  end
end
