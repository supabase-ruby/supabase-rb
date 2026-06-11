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

## Differences from supabase-py

### `timeout:`, `verify:`, `proxy:` are active constructor parameters

In `supabase-py` these three kwargs on `SyncFunctionsClient.__init__` are
**deprecated**: passing any of them emits a `DeprecationWarning` and the
guidance is to configure the underlying `httpx.Client` instead
(see `functions_client.py`).

In `supabase-rb` they are **active and have well-defined effects** on the
default Faraday session:

| Kwarg     | Type            | Default | Effect                                                                    |
|-----------|-----------------|---------|---------------------------------------------------------------------------|
| `timeout` | `Numeric, nil`  | `60`    | Sets both `Faraday::Connection#options.timeout` and `.open_timeout` (sec).|
| `verify`  | `Boolean`       | `true`  | Becomes `ssl: { verify: ... }` on the Faraday connection (TLS cert check).|
| `proxy`   | `String, nil`   | `nil`   | Passed through as Faraday's `proxy:` option.                              |

```ruby
functions = Supabase::Functions::Client.new(
  base_url: "https://project.supabase.co/functions/v1",
  headers:  { "Authorization" => "Bearer #{key}" },
  timeout:  30,
  verify:   true,
  proxy:    "http://corporate-proxy.local:3128"
)
```

If you pass your own `http_client:` (a pre-built `Faraday::Connection`),
`timeout`/`verify`/`proxy` are ignored — your Faraday is used as-is.

### Retry — opt-in via Faraday middleware

Neither `supabase-py` nor `supabase-rb` retries Edge Function calls
automatically. In Ruby, the idiomatic way to add retries is to inject a
Faraday connection with the [`faraday-retry`][faraday-retry] middleware:

```ruby
require "faraday"
require "faraday/retry"
require "supabase/functions"

http = Faraday.new(url: "https://project.supabase.co/functions/v1") do |f|
  f.request :retry,
            max:            2,
            interval:       0.5,
            backoff_factor: 2,
            retry_statuses: [429, 500, 502, 503, 504],
            # `invoke` always POSTs, so opt POST into the retried set.
            methods:        %i[get head options put delete post],
            # Defaults cover Faraday::TimeoutError + Errno::ETIMEDOUT +
            # Faraday::RetriableResponse — listing them explicitly keeps the
            # set intact when we also want ConnectionFailed.
            exceptions:     [Faraday::ConnectionFailed, Faraday::TimeoutError,
                             Errno::ETIMEDOUT, Faraday::RetriableResponse]
  f.options.timeout      = 60
  f.options.open_timeout = 60
  f.adapter Faraday.default_adapter
end

functions = Supabase::Functions::Client.new(
  base_url:    "https://project.supabase.co/functions/v1",
  headers:     { "Authorization" => "Bearer #{key}" },
  http_client: http
)
```

`faraday-retry` is not a runtime dependency of `supabase-rb`; add
`gem "faraday-retry"` to your `Gemfile` if you want this pattern.

Be mindful that `invoke` is always a POST — by default `faraday-retry`
only retries idempotent methods (`%i[delete get head options put]`), so
you must opt POST in via `methods:` above if you want POST retries.
Functions whose side effects are not idempotent should leave POST out
of `methods:` to avoid double-execution.

[faraday-retry]: https://github.com/lostisland/faraday-retry
