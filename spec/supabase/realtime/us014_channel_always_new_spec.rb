# frozen_string_literal: true

require "supabase/realtime"
require "json"

# US-014: `Client#channel(topic)` must always return a fresh Channel instance
# (no `||=` memoization), and `get_channels` must support multiple channels
# sharing a topic. Mirrors supabase-py's flat-list channel registry.
#
# Breaking change: callers that previously relied on `channel("x")` returning
# the existing instance must now do `get_channels.find { |c| c.topic == "x" }`.
RSpec.describe "US-014: client.channel(topic) is never memoized" do
  let(:socket) { Supabase::Realtime::TestSocket.new }
  let(:client) do
    Supabase::Realtime::Client.new(
      url:    "wss://x.supabase.co/realtime/v1",
      params: { apikey: "anon" },
      socket: socket
    )
  end

  it "returns a brand-new Channel each call (AC #1)" do
    a = client.channel("public:users")
    b = client.channel("public:users")
    expect(a).not_to be(b)
    expect(a.topic).to eq("realtime:public:users")
    expect(b.topic).to eq("realtime:public:users")
  end

  it "lets get_channels return multiple channels on one topic (AC #2)" do
    a = client.channel("public:users")
    b = client.channel("public:users")
    expect(client.get_channels).to contain_exactly(a, b)
    expect(client.get_channels.count { |c| c.topic == "realtime:public:users" }).to eq(2)
  end

  it "subscribe → remove → channel(topic) returns a NEW instance with a NEW join ref (AC #3)" do
    client.connect

    first = client.channel("public:users")
    first.subscribe
    first_ref = first.join_push.ref
    expect(first_ref).not_to be_nil

    client.remove_channel(first)
    expect(client.get_channels).not_to include(first)

    second = client.channel("public:users")
    expect(second).not_to be(first)
    expect(second.topic).to eq(first.topic)

    second.subscribe
    second_ref = second.join_push.ref
    expect(second_ref).not_to be_nil
    expect(second_ref).not_to eq(first_ref)
  end

  it "documents the AC #4 migration path — get_channels.find { ... } locates an existing channel by topic" do
    a = client.channel("public:users")
    _b = client.channel("public:posts")
    located = client.get_channels.find { |c| c.topic == "realtime:public:users" }
    expect(located).to be(a)
  end
end
