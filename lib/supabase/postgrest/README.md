# `supabase-postgrest`

Ruby client for [PostgREST](https://postgrest.org). Query builder for
PostgREST-backed Supabase tables, RPCs, and views. Mirrors the public surface
of [`postgrest`](https://github.com/supabase/supabase-py/tree/main/src/postgrest)
in Python.

- Source: [github.com/supabase-rb/client](https://github.com/supabase-rb/client)

## Installation

```ruby
gem "supabase-postgrest"
```

Then `bundle install`. (Requires Ruby >= 3.0.)

## Usage

```ruby
require "supabase/postgrest"

client = Supabase::Postgrest::Client.new(
  base_url: "https://your-project.supabase.co/rest/v1",
  headers:  { "apikey" => key, "Authorization" => "Bearer #{token}" }
)
```

### Select

```ruby
users = client.from("users")
              .select("id, name, email")
              .eq("status", "active")
              .gt("age", 18)
              .order("created_at", desc: true)
              .limit(10)
              .execute
users.data    # => [{ "id" => ..., "name" => ..., ... }, ...]
users.count   # => populated when select(count: "exact")
```

### Insert / Upsert / Update / Delete

```ruby
client.from("users").insert({ "name" => "Ada" }).execute
client.from("users").upsert({ "id" => 1, "name" => "Ada" }, on_conflict: "id").execute
client.from("users").update({ "name" => "Ada Lovelace" }).eq("id", 1).execute
client.from("users").delete.eq("id", 1).execute
```

### RPC

```ruby
client.rpc("increment", { x: 1 }).execute
```

### Filters

Every PostgREST filter operator is supported: `eq`, `neq`, `gt/gte/lt/lte`,
`like` / `ilike` (+ `_all_of` / `_any_of` variants), `is_`, `in_`,
`contains` / `contained_by`, `range_lt/gt/gte/lte/adjacent`, `overlaps`,
`fts/plfts/phfts/wfts`, `match`, `or_`, `not_`. See
[`request_builder.rb`](request_builder.rb) for the full surface.

## Async variant

```ruby
require "supabase/postgrest/async"

async_client = Supabase::Postgrest::Async::Client.new(
  base_url: ENV["SUPABASE_URL"] + "/rest/v1",
  headers:  { "apikey" => key, "Authorization" => "Bearer #{token}" }
)

Async do |task|
  jobs = ids.map { |id| task.async { async_client.from("users").select("*").eq("id", id).execute } }
  jobs.map(&:wait)
end
```

A one-method override on top of `Postgrest::Client` that swaps in
[`async-http-faraday`](https://github.com/socketry/async-http-faraday) for
fiber-parallel I/O.
