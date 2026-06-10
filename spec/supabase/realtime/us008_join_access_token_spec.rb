# frozen_string_literal: true

require "supabase/realtime"
require "json"

# US-008 / F-C3: every phx_join frame must carry the socket's current
# access_token under payload.config.access_token. Otherwise private channels
# get rejected by RLS because the gateway never sees the caller's JWT.
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
    it "puts the socket's access_token into payload.config.access_token" do
      client  = build_client(token: "jwt-from-signin")
      client.connect

      channel = client.channel("public:users")
      channel.subscribe

      join = socket.last_sent_frame
      expect(join["event"]).to eq("phx_join")
      expect(join["payload"]["config"]).to include("access_token" => "jwt-from-signin")
    end

    it "still emits the key (as nil) when the socket has no access_token yet" do
      client = build_client
      client.connect

      channel = client.channel("public:users")
      channel.subscribe

      join = socket.last_sent_frame
      expect(join["payload"]["config"]).to have_key("access_token")
      expect(join["payload"]["config"]["access_token"]).to be_nil
    end
  end

  describe "#rejoin (AC #1: same path covers reconnect)" do
    it "rebuilds the join payload with the current access_token" do
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
      expect(rejoin_frame["payload"]["config"])
        .to include("access_token" => "rotated-jwt")
    end
  end

  describe "set_auth → next subscribe uses rotated token (AC #4)" do
    it "the join payload for a fresh channel reflects the new token" do
      client = build_client(token: "initial-jwt")
      client.connect

      client.set_auth("new-jwt")
      socket.reset_sent_frames

      client.channel("public:posts").subscribe

      join = socket.last_sent_frame
      expect(join["event"]).to eq("phx_join")
      expect(join["topic"]).to eq("realtime:public:posts")
      expect(join["payload"]["config"])
        .to include("access_token" => "new-jwt")
    end

    it "honors set_auth even when the initial socket had no token at all" do
      client = build_client
      client.connect
      client.set_auth("first-jwt")
      socket.reset_sent_frames

      client.channel("public:items").subscribe

      expect(socket.last_sent_frame["payload"]["config"])
        .to include("access_token" => "first-jwt")
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
      expect(socket.last_sent_frame["payload"]["config"]["access_token"])
        .to eq(client.access_token)
    end
  end
end
