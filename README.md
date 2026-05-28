# supabase-rb

[![Ruby](https://img.shields.io/badge/ruby-%3E%3D%203.0-red)](https://www.ruby-lang.org)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

Ruby client for [Supabase](https://supabase.com). Mirrors the public surface of
[`supabase-py`](https://github.com/supabase/supabase-py) so anyone porting from
Python (or reading the Python docs) can find the Ruby equivalent by name.

This repo is a monorepo of six gems:

| Gem | What it does |
|---|---|
| `supabase`            | Umbrella — `Supabase.create_client(url:, key:)` exposes all sub-clients |
| `supabase-auth`       | Supabase Auth / GoTrue (sign in/out, sessions, MFA, JWT, OAuth, admin) |
| `supabase-postgrest`  | PostgREST query builder (select/insert/update/upsert/delete/RPC) |
| `supabase-storage`    | Storage REST API (bucket CRUD, file upload/download, signed URLs) |
| `supabase-functions`  | Edge Function invocation (per-call body/headers/region/response type) |
| `supabase-realtime`   | Phoenix Channels protocol + dispatch (transport-pluggable) |

Each sub-gem has a parallel `Supabase::<X>::Async::Client` built on
[`async-http-faraday`](https://github.com/socketry/async-http-faraday) for
fiber-parallel I/O. They are loaded only when `require "supabase/<x>/async"` so
sync-only users pay zero cost.

## Installation

Use the umbrella for the typical case:

```ruby
gem "supabase"
```

…or pull just the sub-gems you need:

```ruby
gem "supabase-auth"
gem "supabase-postgrest"
gem "supabase-storage"
gem "supabase-functions"
gem "supabase-realtime"
```

Then `bundle install`.

## Quick start (umbrella)

```ruby
require "supabase"

client = Supabase.create_client(
  supabase_url: "https://your-project.supabase.co",
  supabase_key: ENV["SUPABASE_ANON_KEY"]
)

# Auth
client.auth.sign_in_with_password(email: "user@example.com", password: "pw")

# PostgREST
users = client.from("users").select("id, name").eq("status", "active").execute

# Storage
client.storage.from("avatars").upload("user1.png", File.binread("user1.png"),
                                       content_type: "image/png")

# Edge Functions
result = client.functions.invoke("hello-world", body: { name: "Ada" })

# Realtime (see Realtime section — you bring the WebSocket transport)
channel = client.realtime.channel("realtime:public:users")
channel.on_postgres_changes("INSERT", schema: "public", table: "users") { |p| puts p }
```

Pass `async: true` to swap Auth/PostgREST/Storage/Functions into their async
variants (Realtime stays sync — see the Realtime section):

```ruby
require "async"

async_client = Supabase.create_client(
  supabase_url: ENV["SUPABASE_URL"], supabase_key: ENV["SUPABASE_ANON_KEY"], async: true
)

Async do |task|
  jobs = user_ids.map do |id|
    task.async { async_client.from("users").select("*").eq("id", id).execute }
  end
  jobs.map(&:wait)
end
```

URLs for each sub-client are derived from the project URL:

| Sub-client | URL |
|---|---|
| Auth      | `<project>/auth/v1` |
| PostgREST | `<project>/rest/v1` |
| Storage   | `<project>/storage/v1` |
| Functions | `<project>/functions/v1` |
| Realtime  | `wss://<host>/realtime/v1/websocket` |

`client.set_auth(jwt)` rotates the `Authorization` header across every
sub-client at once — useful after `auth.sign_in` returns a fresh user JWT.

---

## supabase-auth

```ruby
require "supabase/auth"

client = Supabase::Auth::Client.new(
  url: "https://your-project.supabase.co/auth/v1",
  headers: { "apiKey" => "your-anon-key" }
)

response = client.sign_in_with_password(email: "user@example.com", password: "pw")
session  = client.get_session
user     = client.get_user
```

### Sign-in methods

```ruby
client.sign_in_with_password(email:, password:)
client.sign_in_with_otp(email:)             # magic link
client.sign_in_with_otp(phone:)             # SMS OTP
client.sign_in_with_oauth(provider: "google")
client.sign_in_with_sso(domain: "company.com")
client.sign_in_with_id_token(provider:, token:)
client.sign_in_anonymously
client.sign_out
```

### Session lifecycle

```ruby
client.set_session("access_token", "refresh_token")
client.refresh_session
client.exchange_code_for_session(auth_code: "code")   # PKCE

subscription = client.on_auth_state_change { |event, session| ... }
subscription.unsubscribe.call
```

Events: `SIGNED_IN`, `SIGNED_OUT`, `TOKEN_REFRESHED`, `USER_UPDATED`,
`MFA_CHALLENGE_VERIFIED`, `PASSWORD_RECOVERY`.

### MFA

```ruby
enrolled  = client.mfa.enroll(factor_type: "totp")
challenge = client.mfa.challenge(factor_id: enrolled["id"])
client.mfa.verify(factor_id: enrolled["id"], challenge_id: challenge.id, code: "123456")
```

### JWT verification

```ruby
claims = client.get_claims(jwt: "eyJhbG...")
claims.claims   # decoded payload
claims.headers  # JWT headers
```

Supports HS256, RS256, ES256, PS256+ (and their 384/512 variants).

### Admin API

```ruby
admin = Supabase::Auth::AdminApi.new(
  url: "https://your-project.supabase.co/auth/v1",
  headers: { "Authorization" => "Bearer #{service_role}", "apiKey" => service_role }
)

admin.create_user(email:, password:)
admin.list_users(page: 1, per_page: 50)
admin.invite_user_by_email("user@example.com")
admin.generate_link(type: "signup", email:, password:)

# OAuth 2.1 client administration (when the OAuth server feature is enabled)
admin.oauth.create_client(client_name:, redirect_uris:)
admin.oauth.list_clients(page: 1, per_page: 20)
admin.oauth.regenerate_client_secret("client-uuid")
```

### Constructor options

```ruby
Supabase::Auth::Client.new(
  url:                   "...",
  headers:               { "apiKey" => "..." },
  auto_refresh_token:    true,
  persist_session:       true,
  detect_session_in_url: true,
  flow_type:             "implicit",   # or "pkce"
  storage:               custom_storage
)
```

---

## supabase-postgrest

```ruby
require "supabase/postgrest"

client = Supabase::Postgrest::Client.new(
  base_url: "https://your-project.supabase.co/rest/v1",
  headers:  { "apikey" => key, "Authorization" => "Bearer #{token}" }
)

# SELECT with filters / order / limit
users = client.from("users")
              .select("id, name, email")
              .eq("status", "active")
              .gt("age", 18)
              .order("created_at", desc: true)
              .limit(10)
              .execute
users.data    # => [{ "id" => ..., "name" => ..., ... }, ...]
users.count   # => populated when select(count: "exact")

# Insert
client.from("users").insert({ "name" => "Ada" }).execute

# Upsert
client.from("users").upsert({ "id" => 1, "name" => "Ada" }, on_conflict: "id").execute

# Update + filter
client.from("users").update({ "name" => "Ada Lovelace" }).eq("id", 1).execute

# Delete + filter
client.from("users").delete.eq("id", 1).execute

# RPC
client.rpc("increment", { x: 1 }).execute
```

Every PostgREST filter operator is supported: `eq`, `neq`, `gt/gte/lt/lte`,
`like` / `ilike` (+ `_all_of` / `_any_of` variants), `is_`, `in_`,
`contains` / `contained_by`, `range_lt/gt/gte/lte/adjacent`, `overlaps`,
`fts/plfts/phfts/wfts`, `match`, `or_`, `not_`. See
[`request_builder.rb`](lib/supabase/postgrest/request_builder.rb) for the
full surface.

`Postgrest::Async::Client` (loaded via `require "supabase/postgrest/async"`)
is a one-method override that swaps in `async-http-faraday`. Use it inside
`Async do ... end` to fan out concurrent queries on a single fiber.

---

## supabase-storage

```ruby
require "supabase/storage"

storage = Supabase::Storage::Client.new(
  base_url: "https://your-project.supabase.co/storage/v1",
  headers:  { "apikey" => key, "Authorization" => "Bearer #{token}" }
)

# Bucket management
storage.create_bucket("avatars", public: true)
storage.list_buckets
storage.get_bucket("avatars")
storage.update_bucket("avatars", public: false)
storage.empty_bucket("avatars")
storage.delete_bucket("avatars")

# File operations (scoped to one bucket via `.from`)
bucket = storage.from("avatars")
bucket.upload("user1.png", File.binread("user1.png"), content_type: "image/png")
bucket.download("user1.png")    # => bytes
bucket.list("folder/")
bucket.remove(["user1.png"])
bucket.move("user1.png", "archive/user1.png")
bucket.copy("user1.png", "backups/user1.png")
bucket.exists?("user1.png")

# Signed URLs
bucket.create_signed_url("user1.png", expires_in: 3600)
bucket.create_signed_urls(["user1.png", "user2.png"], expires_in: 3600)
bucket.get_public_url("user1.png")

# Signed upload URL (so a browser can upload directly to Storage)
signed = bucket.create_signed_upload_url("user1.png")
bucket.upload_to_signed_url("user1.png", token: signed.token, file: bytes)
```

Upload accepts `String` (raw bytes), any `IO`, `StringIO`, or `Pathname`.
Multipart encoding is handled by `faraday-multipart`. Metadata Hashes are
base64-encoded into the `x-metadata` header automatically.

`Storage::Async::Client` mirrors the API for concurrent file ops inside `Async do`.

---

## supabase-functions

```ruby
require "supabase/functions"

functions = Supabase::Functions::Client.new(
  base_url: "https://your-project.supabase.co/functions/v1",
  headers:  { "Authorization" => "Bearer #{key}" }
)

# Simple invoke (POST + JSON body)
response = functions.invoke("hello", body: { name: "Ada" })
response.data    # => parsed JSON or raw bytes
response.status
response.headers

# Custom HTTP method, headers, query, region routing
functions.invoke(
  "ingest",
  method:  "PUT",
  headers: { "X-Trace-Id" => "abc" },
  query:   { tenant: "x" },
  region:  Supabase::Functions::Types::FunctionRegion::US_EAST_1,
  body:    payload_hash
)
```

`response.data` is auto-parsed when the response `Content-Type` is JSON,
otherwise the raw body. Force parsing with `response_type: :json`.

Errors raise `FunctionsHttpError` (function-side) or `FunctionsRelayError`
(detected via the server's `x-relay-header`).

`Functions::Async::Client` is the async twin.

---

## supabase-realtime

Implements the [Phoenix Channels](https://hexdocs.pm/phoenix/channels.html)
protocol against a **pluggable Socket interface**. The protocol + dispatch
(channel state machine, presence sync, listener routing, push/reply tracking)
is fully implemented and tested. A real WebSocket transport plugs in through
the `Supabase::Realtime::Socket` interface; the gem ships one production
adapter built on `websocket-client-simple`.

This mirrors `supabase-py`'s decision to ship sync realtime as
`NotImplementedError`: WebSocket I/O is fundamentally event-driven and a
naive sync wrapper is more harmful than no wrapper at all. The
websocket-client-simple adapter runs the read loop on a background thread,
which means listener callbacks fire on that thread — bring your own
thread-safety to anything they touch.

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

For unit testing, ship `Supabase::Realtime::TestSocket` — an in-memory Socket
implementation with `inject(frame)` and `sent_frames` capture. See
[`spec/supabase/realtime/`](spec/supabase/realtime/) for usage.

### Implementing your own Socket adapter

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

---

## Ruby-specific additions

The Ruby port carries two intentional enhancements over `supabase-py`,
documented here so they don't get "fixed" to match Python.

### `AuthPKCEError`

`Supabase::Auth::Errors::AuthPKCEError` is a dedicated exception for
PKCE-flow failures (missing or invalid `code_verifier` during
`exchange_code_for_session`). Python raises a generic `AuthError`; the
dedicated class gives callers a precise `rescue` target.

### Explicit JWT algorithm → digest mapping

`Supabase::Auth::Client::ALG_TO_DIGEST` is a frozen lookup table:

```ruby
ALG_TO_DIGEST = {
  "RS256" => "SHA256", "RS384" => "SHA384", "RS512" => "SHA512",
  "ES256" => "SHA256", "ES384" => "SHA384", "ES512" => "SHA512",
  "PS256" => "SHA256", "PS384" => "SHA384", "PS512" => "SHA512"
}.freeze
```

Python resolves algorithms dynamically via `PyJWT.get_algorithm_by_name`.
The Ruby table makes the supported set readable in one place and fails fast
(`AuthInvalidJwtError`) on unsupported `alg` values.

---

## Development

### Prerequisites

- Ruby >= 3.0
- Docker & Docker Compose (for Auth integration tests against live GoTrue)

### Setup

```bash
bundle install
```

The repo's `Gemfile` loads all six sub-gemspecs at once. To consume sub-gems
individually in your own project, depend on them by name as shown in the
Installation section.

### Running tests

Auth integration specs need the GoTrue infrastructure on ports 9996–9999:

```bash
docker compose -f infra/docker-compose.yml up -d
```

Run the full suite:

```bash
bundle exec rspec
```

Run a single sub-library's specs:

```bash
bundle exec rspec spec/supabase/postgrest/
bundle exec rspec spec/supabase/storage/
bundle exec rspec spec/supabase/functions/
bundle exec rspec spec/supabase/realtime/
bundle exec rspec spec/supabase/client_spec.rb     # umbrella
```

Coverage is generated by SimpleCov to `coverage/index.html`.

## License

MIT
