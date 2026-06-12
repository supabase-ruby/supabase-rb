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

## Модель конкурентности

Все пользовательские колбэки realtime исполняются на **read-треде websocket-
гема** — том же, который читает фреймы из сокета. Транспорт по умолчанию
(`Sockets::WebsocketClientSimple`) построен на
[`websocket-client-simple`](https://github.com/shokai/websocket-client-simple),
который спавнит этот тред сам в `connect`-блоке. Если вы инжектите свой
адаптер (`include Supabase::Realtime::Socket`), правила те же — `Client`
дёргает `message_callbacks` синхронно из `fire_message`, поэтому колбэк
исполняется на том же треде, который вы пришлёте.

**Где какие колбэки исполняются:**

| Колбэк                                                                            | Тред                                                                       |
|-----------------------------------------------------------------------------------|----------------------------------------------------------------------------|
| `channel.on_broadcast`, `on_postgres_changes`, `on_system`, `on_close`, `on_error`| read-тред транспорта                                                       |
| `presence.on_sync`, `on_join`, `on_leave`                                         | read-тред транспорта (но фанятся ПОСЛЕ освобождения внутреннего mutex'а)   |
| Блок `channel.subscribe { \|status, err\| ... }`                                  | read-тред транспорта                                                       |
| `push.receive(:ok / :error) { ... }`                                              | read-тред (если ответ пришёл) ИЛИ push-timeout-тред (если сработал watchdog) |
| `client.on_reconnect_failed { \|err\| ... }`                                      | reconnect-тред (см. секцию ниже)                                           |

**Что от вас требуется внутри колбэка:**

1. **Не блокировать.** Любая длительная операция в колбэке (синхронный HTTP,
   тяжёлый БД-запрос, `sleep`, `Mutex#synchronize` на чужом локе) задерживает
   обработку следующих фреймов на том же сокете. Если задержка превысит
   `heartbeat_interval` — heartbeat не отправится, сервер дропнет соединение,
   и стартует фоновый реконнект. Правильный паттерн — внутри колбэка только
   декодинг payload + пушок в очередь / Sidekiq / собственный пул тредов;
   тяжёлая работа — снаружи.

2. **Тред-безопасность общего состояния.** Колбэк работает на read-треде, а
   ваш основной код (Rails-контроллер, Sidekiq-воркер, ActiveRecord-
   соединение) — на других. Любое разделяемое состояние, к которому вы
   обращаетесь и из колбэка, и снаружи, должно быть защищено вами — мьютексом,
   `Concurrent::Map`, атомиком, очередью с потокобезопасной семантикой и т.п.
   Внутреннее состояние гема уже синхронизировано: `presence.state` возвращает
   shallow-копию снимка (US-007), `Push` разруливает гонку «timeout vs reply»
   под собственным мьютексом, `Channel#join_state` обновляется только из read-
   треда. Всё, что лежит ВНЕ гема, — на пользователе.

3. **Исключения уже изолированы.** `raise StandardError` из любого
   пользовательского колбэка ловится `CallbackSafety` (US-002), логируется в
   `Realtime::Client.new(logger:)` (или `$stderr` через `Kernel#warn`, если
   логгер не задан) и **не убивает read-тред** — соседние колбэки и
   следующие фреймы продолжают работать. Это страховка, а не штатный канал
   ошибок: пользовательский код всё равно должен ловить свои ошибки явно,
   иначе лог быстро превратится в шум.

**Отличие от `supabase-py`.** Python-клиент построен на `asyncio`: read-loop
там — это `await`-цикл внутри одной корутины, и колбэки (`async def`)
дёргаются `await callback(payload)` в том же event-loop'е. Конкуренции по
shared state нет в принципе (asyncio однопоточен), но блокирующий колбэк
блокирует весь loop, а не «один тред из пула». В rb read-loop — это
настоящий `Thread`, поэтому правила противоположные: блокировка локальна
(страдает только один сокет), но shared state требует реальной
синхронизации.

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
  `websocket-client-simple`), `Client#connect` ретраит с экспоненциальным
  бэкоффом как в py (`initial_backoff * 2^(n-1)`, кап 60 с) до `max_retries`
  попыток суммарно и затем пробрасывает последнюю ошибку. При
  `auto_reconnect: false` первая же ошибка пробрасывается сразу — тоже
  паритет с py. Бэкграунд-цикл и `on_reconnect_failed` относятся к
  ситуациям «соединение установилось и потом упало» и «транспорт сообщил
  об ошибке асинхронно» (некоторые адаптеры открывают сокет в фоне и не
  бросают из `connect` синхронно — тогда первичный сбой тоже уходит в
  бэкграунд-цикл).

Сводка контракта:

| Сценарий                                       | Поведение                                          |
|------------------------------------------------|----------------------------------------------------|
| Первичный `connect`, сервер недоступен (sync)  | ретраи с бэкоффом, затем `raise` (как в py)        |
| То же при `auto_reconnect: false`              | `raise` сразу, без ретраев (как в py)              |
| Транспорт сигналит сбой асинхронно             | бэкграунд-реконнект → `on_reconnect_failed`        |
| Установленный сокет, сервер дропнул            | бэкграунд-реконнект до `max_retries`               |
| Все `max_retries` исчерпаны (бэкграунд)        | `on_reconnect_failed.(last_error)`                 |
| Явный `disconnect` во время бэкоффа            | ретраи прекращаются, колбэк НЕ вызывается          |

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
