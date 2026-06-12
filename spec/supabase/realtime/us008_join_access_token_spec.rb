# frozen_string_literal: true

require "supabase/realtime"
require "json"

# US-008 / F-C3 (D1 fix): every phx_join frame must carry the socket's current
# access_token at the ROOT of the payload (a sibling of "config"), matching
# supabase-py `channel.py`:
#
#   config_payload = { "config": { ... } }
#   if self.socket.access_token:
#       config_payload["access_token"] = self.socket.access_token
#
# The Phoenix gateway reads `payload.access_token`, NOT
# `payload.config.access_token`. Nesting it under config (the prior behavior)
# meant private channels / RLS-scoped postgres_changes never saw the caller's
# JWT and authorized with the URL apikey only. Per supabase-py the key is also
# OMITTED entirely when there is no token, rather than emitted as nil.
#
# The source of truth for the token is `Supabase::Realtime::Client#access_token`,
# which is the same field `set_auth(token)` rotates — so the next subscribe()
# after a rotation must use the new value.
RSpec.describe "US-008: Realtime join payload contains access_token" do
  let(:socket) { fake_realtime_socket }

  def build_client(token: nil)
    params = token ? { access_token: token } : {}
    Supabase::Realtime::Client.new(
      url:     "wss://x.supabase.co/realtime/v1",
      params:  params,
      socket:  socket
    )
  end

  describe "#subscribe (AC #3)" do
    it "puts the socket's access_token at payload root (sibling of config)" do
      client  = build_client(token: "jwt-from-signin")
      client.connect

      channel = client.channel("public:users")
      channel.subscribe

      join = socket.last_sent_frame
      expect(join["event"]).to eq("phx_join")
      expect(join["payload"]).to include("access_token" => "jwt-from-signin")
      # Must NOT be nested under config — that's the D1 bug.
      expect(join["payload"]["config"]).not_to have_key("access_token")
    end

    it "omits the access_token key entirely when the socket has no token yet" do
      client = build_client
      client.connect

      channel = client.channel("public:users")
      channel.subscribe

      join = socket.last_sent_frame
      expect(join["payload"]).not_to have_key("access_token")
      expect(join["payload"]["config"]).not_to have_key("access_token")
    end
  end

  describe "#rejoin (AC #1: same path covers reconnect)" do
    it "rebuilds the join payload with the current access_token at root" do
      client  = build_client(token: "old-jwt")
      client.connect
      channel = client.channel("public:users")
      channel.subscribe
      socket.simulate_recv(
        event:   "phx_reply",
        topic:   channel.topic,
        payload: { "status" => "ok", "response" => {} },
        ref:     socket.last_sent_frame["ref"]
      )

      client.set_auth("rotated-jwt")
      socket.reset_sent_frames
      channel.rejoin

      rejoin_frame = socket.last_sent_frame
      expect(rejoin_frame["event"]).to eq("phx_join")
      expect(rejoin_frame["payload"]).to include("access_token" => "rotated-jwt")
      expect(rejoin_frame["payload"]["config"]).not_to have_key("access_token")
    end

    it "drops a previously-set token from the rejoin payload after it is cleared" do
      client  = build_client(token: "old-jwt")
      client.connect
      channel = client.channel("public:users")
      channel.subscribe
      socket.simulate_recv(
        event:   "phx_reply",
        topic:   channel.topic,
        payload: { "status" => "ok", "response" => {} },
        ref:     socket.last_sent_frame["ref"]
      )

      client.set_auth(nil)
      socket.reset_sent_frames
      channel.rejoin

      # Reused payload hash must not leak the stale token key.
      expect(socket.last_sent_frame["payload"]).not_to have_key("access_token")
    end
  end

  describe "set_auth → next subscribe uses rotated token (AC #4)" do
    it "the join payload for a fresh channel reflects the new token at root" do
      client = build_client(token: "initial-jwt")
      client.connect

      client.set_auth("new-jwt")
      socket.reset_sent_frames

      client.channel("public:posts").subscribe

      join = socket.last_sent_frame
      expect(join["event"]).to eq("phx_join")
      expect(join["topic"]).to eq("realtime:public:posts")
      expect(join["payload"]).to include("access_token" => "new-jwt")
    end

    it "honors set_auth even when the initial socket had no token at all" do
      client = build_client
      client.connect
      client.set_auth("first-jwt")
      socket.reset_sent_frames

      client.channel("public:items").subscribe

      expect(socket.last_sent_frame["payload"]).to include("access_token" => "first-jwt")
    end
  end

  describe "AC #2: shared source of truth with set_auth" do
    it "reads from the same field set_auth writes (Client#access_token)" do
      client = build_client(token: "boot-jwt")
      client.connect
      expect(client.access_token).to eq("boot-jwt")

      client.set_auth("rotated")
      expect(client.access_token).to eq("rotated")

      client.channel("public:x").subscribe
      expect(socket.last_sent_frame["payload"]["access_token"])
        .to eq(client.access_token)
    end
  end
end
