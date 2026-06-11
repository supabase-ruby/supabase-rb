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

The same caveat applies to the channel rejoin timer: after a join error or
timeout, the channel schedules a retry via `Supabase::Realtime::Timer`, which
runs the rejoin on a background thread once the backoff delay elapses.
Anything the rejoin path mutates (state shared with listener callbacks, the
underlying `Socket`, etc.) must tolerate being touched from an arbitrary
thread — consistent with the existing listener-thread model.

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

## Realtime reconnect: отличие от supabase-py

`Realtime::Client` отличается от `supabase-py` (`realtime/_async/client.py:141-193`)
тем, как сообщает о реконнекте — это намеренное отклонение, продиктованное
разницей моделей конкурентности (треды vs `asyncio`):

- **Реконнект всегда фоновый.** Когда сервер закрывает сокет, rb запускает
  отдельный тред с экспоненциальным бэкоффом (`initial_backoff` ×
  `2^(n-1)`, капается на 60 с) и пытается переподключиться до `max_retries`
  раз. В py та же логика «живёт» внутри корутины `connect()` — она
  возвращает управление либо когда сокет встал, либо когда был исчерпан
  бюджет ретраев (через `raise`).
- **Окончательная неудача доходит через колбэк, а не исключение.** После
  исчерпания `max_retries` rb вызывает каждый зарегистрированный колбэк
  `on_reconnect_failed { |last_error| ... }` ровно один раз, с последним
  пойманным исключением транспорта. Колбэки оборачиваются `CallbackSafety`
  — раис в одном пользовательском блоке не блокирует остальные:

  ```ruby
  client.on_reconnect_failed do |err|
    logger.error("realtime down for good: #{err.class}: #{err.message}")
    notify_oncall!
  end
  ```

  Если `disconnect` был вызван явно — колбэк не дёргается (это была
  намеренная остановка, не сбой).
- **Явный `connect` к недоступному серверу не «успешен молча».** Первичный
  `client.connect` ходит на транспорт синхронно: если `Socket#connect`
  бросает (типично `Errno::ECONNREFUSED` / `SocketError` от
  `websocket-client-simple`), это исключение пробрасывается из
  `Client#connect` сразу, без внутреннего ретрая. Поведение совпадает с
  py: `await connect()` тоже бросает на постоянной ошибке. Бэкграунд-цикл
  и `on_reconnect_failed` относятся ИСКЛЮЧИТЕЛЬНО к ситуации
  «соединение установилось и потом упало», а не «никогда не поднималось
  первый раз».

Сводка контракта:

| Сценарий                                  | Поведение                            |
|-------------------------------------------|--------------------------------------|
| Первичный `connect`, сервер недоступен    | `raise` (как в py)                   |
| Установленный сокет, сервер дропнул       | бэкграунд-реконнект до `max_retries` |
| Все `max_retries` исчерпаны               | `on_reconnect_failed.(last_error)`   |
| Явный `disconnect` во время бэкоффа       | колбэк НЕ вызывается                 |

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
