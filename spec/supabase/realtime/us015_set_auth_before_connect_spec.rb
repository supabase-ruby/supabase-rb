# frozen_string_literal: true

require "supabase/realtime"
require "json"

# US-015: calling `realtime.set_auth(token)` BEFORE `connect` must not lose the
# token. The token write is unconditional; the ACCESS_TOKEN frame fan-out is the
# only thing gated by socket state. The next `subscribe` after a `connect` then
# picks the token up via `Channel#inject_postgres_changes_bindings` → join
# payload.
RSpec.describe "US-015: set_auth before connect keeps the token" do
  let(:socket) { fake_realtime_socket }

  def build_client(params: {})
    Supabase::Realtime::Client.new(
      url:    "wss://x.supabase.co/realtime/v1",
      params: params,
      socket: socket
    )
  end

  describe "AC #2: token is written to @access_token / @params regardless of socket state" do
    it "remembers the token when the socket has never been connected" do
      client = build_client
      expect(socket.connected?).to be false

      client.set_auth("offline-jwt")

      expect(client.access_token).to eq("offline-jwt")
      expect(client.params["access_token"]).to eq("offline-jwt")
    end

    it "remembers the token even when the socket has been explicitly disconnected" do
      client = build_client
      client.connect
      client.disconnect
      expect(socket.connected?).to be false

      client.set_auth("post-close-jwt")

      expect(client.access_token).to eq("post-close-jwt")
      expect(client.params["access_token"]).to eq("post-close-jwt")
    end
  end

  describe "AC #3: ACCESS_TOKEN frame is only emitted when connected" do
    it "does not push an access_token frame when the socket is offline" do
      client = build_client
      client.set_auth("offline-jwt")

      expect(socket.sent_events).not_to include("access_token")
    end
  end

  describe "AC #4: set_auth(t) → connect → subscribe puts the token in the join payload" do
    it "carries the offline-set token through to the very first phx_join" do
      client = build_client
      client.set_auth("set-before-connect-jwt")
      client.connect

      client.channel("public:users").subscribe

      join = socket.last_sent_frame
      expect(join["event"]).to eq("phx_join")
      expect(join["topic"]).to eq("realtime:public:users")
      expect(join["payload"]["config"])
        .to include("access_token" => "set-before-connect-jwt")
    end

    it "uses the most-recent offline set_auth value if called multiple times before connect" do
      client = build_client
      client.set_auth("first")
      client.set_auth("second")
      client.set_auth("third")
      client.connect

      client.channel("public:items").subscribe

      expect(socket.last_sent_frame["payload"]["config"])
        .to include("access_token" => "third")
    end
  end
end
