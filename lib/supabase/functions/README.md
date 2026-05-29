# `supabase-functions`

Ruby client for [Supabase Edge Functions](https://supabase.com/docs/guides/functions).
Per-call control over body, headers, HTTP method, region routing, and
response parsing. Mirrors the public surface of
[`supabase_functions`](https://github.com/supabase/supabase-py/tree/main/src/functions)
in Python.

- Source: [github.com/supabase-rb/client](https://github.com/supabase-rb/client)

## Installation

```ruby
gem "supabase-functions"
```

Then `bundle install`. (Requires Ruby >= 3.0.)

## Usage

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
```

### Custom method / headers / query / region

```ruby
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

### Errors

`FunctionsHttpError` is raised on a function-side error response.
`FunctionsRelayError` is raised when the server's `x-relay-header` signals a
relay failure.

## Async variant

```ruby
require "supabase/functions/async"

async = Supabase::Functions::Async::Client.new(
  base_url: ENV["SUPABASE_URL"] + "/functions/v1",
  headers:  { "Authorization" => "Bearer #{key}" }
)

Async do
  response = async.invoke("hello", body: { name: "Ada" })
end
```
