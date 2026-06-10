# `supabase-functions`

Ruby client for [Supabase Edge Functions](https://supabase.com/docs/guides/functions).
Per-call control over body, headers, region routing, and response parsing.
Mirrors the public surface of
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
raw = functions.invoke("hello", body: { name: "Ada" })
# => the raw response body as a String (default). Parsing is opt-in:

data = functions.invoke("hello", body: { name: "Ada" }, response_type: :json)
# => parsed JSON (Hash / Array / scalar). Same shape as supabase-py.

# For the legacy wrapper carrying status + headers, pass
# `return_response: true` — note: that path is deprecated.
```

### Custom headers / region

```ruby
functions.invoke(
  "ingest",
  headers: { "X-Trace-Id" => "abc" },
  region:  Supabase::Functions::Types::FunctionRegion::US_EAST_1,
  body:    payload_hash
)
```

`#invoke` is always a POST — there is no `method:` kwarg. There is no
`query:` kwarg either (the only query-string consumer is region routing,
which is wired up internally). Both kwargs existed historically to mirror
the supabase-js surface and were dropped in US-030 for parity with
supabase-py.

The return value is the raw response body unless you opt in with
`response_type: :json` — Content-Type is intentionally ignored (parity with
supabase-py, deliberately different from supabase-js).

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
  data = async.invoke("hello", body: { name: "Ada" })
end
```
