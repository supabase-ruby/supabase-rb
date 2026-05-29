# `supabase`

Ruby client for [Supabase](https://supabase.com). Umbrella gem that exposes
Auth, PostgREST, Storage, Edge Functions, and Realtime through a single
`Supabase.create_client` factory.

- Documentation: [supabase.com/docs](https://supabase.com/docs/reference)
- Source: [github.com/supabase-rb/client](https://github.com/supabase-rb/client)

## Installation

```ruby
gem "supabase"
```

Then `bundle install`. (Requires Ruby >= 3.0.)

## Usage

```ruby
require "supabase"

client = Supabase.create_client(
  supabase_url: ENV["SUPABASE_URL"],
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

# Realtime (you bring the WebSocket transport — see supabase-realtime)
channel = client.realtime.channel("realtime:public:users")
channel.on_postgres_changes("INSERT", schema: "public", table: "users") { |p| puts p }
```

Pass `async: true` to swap Auth / PostgREST / Storage / Functions into their
async variants (Realtime stays sync):

```ruby
require "async"

async_client = Supabase.create_client(
  supabase_url: ENV["SUPABASE_URL"],
  supabase_key: ENV["SUPABASE_ANON_KEY"],
  async: true
)

Async do |task|
  jobs = user_ids.map do |id|
    task.async { async_client.from("users").select("*").eq("id", id).execute }
  end
  jobs.map(&:wait)
end
```

`client.set_auth(jwt)` rotates the `Authorization` header across every
sub-client at once — useful after `auth.sign_in` returns a fresh user JWT.

## URL routing

Sub-client URLs are derived from the project URL:

| Sub-client | URL |
|---|---|
| Auth      | `<project>/auth/v1` |
| PostgREST | `<project>/rest/v1` |
| Storage   | `<project>/storage/v1` |
| Functions | `<project>/functions/v1` |
| Realtime  | `wss://<host>/realtime/v1/websocket` |

## Sub-gems

If you only need one piece, depend on the sub-gem directly:

- [`supabase-auth`](https://rubygems.org/gems/supabase-auth)
- `supabase-postgrest`
- `supabase-storage`
- `supabase-functions`
- `supabase-realtime`

See each sub-gem's README for its public surface and examples.
