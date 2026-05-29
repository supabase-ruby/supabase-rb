# `supabase-realtime`

Ruby client for [Supabase Realtime](https://supabase.com/docs/guides/realtime).
Implements the [Phoenix Channels](https://hexdocs.pm/phoenix/channels.html)
protocol against a **pluggable Socket interface**. Broadcast, Presence, and
Postgres Change Data Capture (CDC) — same surface as
[`realtime`](https://github.com/supabase/supabase-py/tree/main/src/realtime)
in Python.

- Source: [github.com/supabase-rb/client](https://github.com/supabase-rb/client)

## Installation

```ruby
gem "supabase-realtime"
```

Then `bundle install`. (Requires Ruby >= 3.0.)

## Design

The protocol layer (channel state machine, presence sync, listener routing,
push/reply tracking) is fully implemented and tested. A real WebSocket
transport plugs in through the `Supabase::Realtime::Socket` interface; the
gem ships one production adapter built on `websocket-client-simple`.

This mirrors `supabase-py`'s decision to ship sync realtime as
`NotImplementedError`: WebSocket I/O is fundamentally event-driven and a
naive sync wrapper is more harmful than no wrapper at all. The
websocket-client-simple adapter runs the read loop on a background thread,
which means listener callbacks fire on that thread — bring your own
thread-safety to anything they touch.

## Usage

```ruby
require "supabase/realtime"
require "supabase/realtime/sockets/websocket_client_simple"

socket = Supabase::Realtime::Sockets::WebsocketClientSimple.new(
  url: "wss://your-project.supabase.co/realtime/v1/websocket?apikey=#{key}"
)
client = Supabase::Realtime::Client.new(
  url:    "wss://your-project.supabase.co/realtime/v1",
  params: { apikey: key, access_token: jwt },
  socket: socket
)
client.connect

channel = client.channel("realtime:public:users")
channel.on_postgres_changes("INSERT", schema: "public", table: "users") { |p| puts p }
channel.on_postgres_changes("*", schema: "public", table: "users") { |p| puts p }
channel.on_broadcast("message") { |p| puts p }
channel.subscribe do |status, err|
  puts status   # "SUBSCRIBED" / "CHANNEL_ERROR" / "TIMED_OUT"
end

channel.send_broadcast("typing", { user: "u1" })
channel.track({ status: "online" })

# Presence
channel.presence.on_sync  { puts channel.presence.state }
channel.presence.on_join  { |key, presence| ... }
channel.presence.on_leave { |key, presence| ... }
```

## Testing

For unit testing, use `Supabase::Realtime::TestSocket` — an in-memory Socket
implementation with `inject(frame)` and `sent_frames` capture. See
[`spec/supabase/realtime/`](../../../spec/supabase/realtime/) in the repo
for usage.

## Implementing your own Socket adapter

Implement these methods (the only contract `Client` assumes):

```ruby
class MyAdapter
  include Supabase::Realtime::Socket

  def connect; ...; open_callbacks.each(&:call); end
  def close;   ...; close_callbacks.each(&:call); end
  def send(payload); ...; end
  def connected?; ...; end

  # Whenever a frame arrives:
  #   message_callbacks.each { |cb| cb.call(raw_json_string) }
end
```
