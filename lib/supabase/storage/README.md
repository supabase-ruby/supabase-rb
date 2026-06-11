# `supabase-storage`

Ruby client for [Supabase Storage](https://supabase.com/docs/guides/storage).
Bucket management, file upload/download, signed URLs, plus the Iceberg
(`analytics`) and vector bucket APIs. Mirrors the public surface of
[`storage3`](https://github.com/supabase/supabase-py/tree/main/src/storage)
in Python.

- Source: [github.com/supabase-rb/client](https://github.com/supabase-rb/client)

## Installation

```ruby
gem "supabase-storage"
```

Then `bundle install`. (Requires Ruby >= 3.0.)

## Usage

```ruby
require "supabase/storage"

storage = Supabase::Storage::Client.new(
  base_url: "https://your-project.supabase.co/storage/v1",
  headers:  { "apikey" => key, "Authorization" => "Bearer #{token}" }
)
```

### Bucket management

```ruby
storage.create_bucket("avatars", public: true)
storage.list_buckets
storage.get_bucket("avatars")
storage.update_bucket("avatars", public: false)
storage.empty_bucket("avatars")
storage.delete_bucket("avatars")
```

### File operations

Scoped to one bucket via `.from`:

```ruby
bucket = storage.from("avatars")
bucket.upload("user1.png", File.binread("user1.png"), content_type: "image/png")
bucket.download("user1.png")    # => bytes
bucket.list("folder/")
bucket.list_v2(prefix: "folder/", limit: 50, cursor: "abc", with_delimiter: true)
bucket.remove(["user1.png"])
bucket.move("user1.png", "archive/user1.png")
bucket.copy("user1.png", "backups/user1.png")
bucket.exists?("user1.png")
```

Upload accepts `String` (raw bytes), any `IO`, `StringIO`, or `Pathname`.
Multipart encoding is handled by `faraday-multipart`. Metadata Hashes are
base64-encoded into the `x-metadata` header automatically.

### Storage upload

`bucket.upload(path, file)` interprets its `file` argument by **class**, not
by content:

> **String = raw bytes; Pathname = file path.**

To avoid the most common porting mistake from supabase-py/storage3:

- **`String` = raw bytes** — the value is uploaded verbatim. Even if the string
  *looks* like a file path (`"user1.png"`), nothing is read from disk. This
  matches storage3's `bytes`/`IO` contract.
- **`Pathname` = file path** — the file at that location on disk is opened
  and streamed.
- `IO` / `StringIO` (or any `#read`-able) — streamed as-is.

```ruby
# String → raw bytes (the literal characters "hello" are uploaded)
bucket.upload("greeting.txt", "hello")

# String holding bytes read from disk → uploaded as those bytes
bucket.upload("user1.png", File.binread("user1.png"), content_type: "image/png")

# Pathname → file on disk is opened and streamed
bucket.upload("user1.png", Pathname.new("user1.png"), content_type: "image/png")
```

If you pass a `String` expecting "upload the file at this path", you will
upload the path string itself. Wrap it in `Pathname.new(...)` or pass
`File.binread(...)` / `File.open(...)`.

### Signed URLs

```ruby
bucket.create_signed_url("user1.png", expires_in: 3600)
bucket.create_signed_urls(["user1.png", "user2.png"], expires_in: 3600)
bucket.get_public_url("user1.png")

# Signed upload URL — so a browser can upload directly to Storage
signed = bucket.create_signed_upload_url("user1.png")
bucket.upload_to_signed_url("user1.png", token: signed.token, file: bytes)
```

### Analytics (Iceberg) buckets

```ruby
storage.analytics.create("warehouse")
storage.analytics.list
storage.analytics.delete("warehouse")
cfg = storage.analytics.catalog("warehouse",
                                access_key_id: "AKIA", secret_access_key: "...")
```

### Vector buckets

```ruby
storage.vectors.create_bucket("embeddings")
storage.vectors.bucket("embeddings").create_index(
  index_name: "docs", dimension: 1536, distance_metric: "cosine"
)
storage.vectors.bucket("embeddings").index("docs").put(records)
storage.vectors.bucket("embeddings").index("docs").query(vector, top_k: 10)
```

## Async variant

```ruby
require "supabase/storage/async"

async = Supabase::Storage::Async::Client.new(
  base_url: ENV["SUPABASE_URL"] + "/storage/v1",
  headers:  { "apikey" => key, "Authorization" => "Bearer #{token}" }
)

Async do
  bucket = async.from("avatars")
  data   = bucket.download("user1.png")
end
```

## Differences from supabase-py

### `timeout:`, `verify:`, `proxy:` are active constructor parameters

In `supabase-py` (`storage3`) these three kwargs on `SyncStorageClient.__init__`
are **deprecated**: passing any of them emits a `DeprecationWarning` and the
guidance is to configure the underlying `httpx.Client` instead
(see `storage3/_sync/client.py`).

In `supabase-rb` they are **active and have well-defined effects** on the
default Faraday session:

| Kwarg     | Type            | Default | Effect                                                                    |
|-----------|-----------------|---------|---------------------------------------------------------------------------|
| `timeout` | `Numeric, nil`  | `20`    | Sets both `Faraday::Connection#options.timeout` and `.open_timeout` (sec).|
| `verify`  | `Boolean`       | `true`  | Becomes `ssl: { verify: ... }` on the Faraday connection (TLS cert check).|
| `proxy`   | `String, nil`   | `nil`   | Passed through as Faraday's `proxy:` option.                              |

```ruby
storage = Supabase::Storage::Client.new(
  base_url: "https://project.supabase.co/storage/v1",
  headers:  { "apikey" => key, "Authorization" => "Bearer #{token}" },
  timeout:  30,
  verify:   true,
  proxy:    "http://corporate-proxy.local:3128"
)
```

The 20-second default mirrors `storage3`'s `DEFAULT_TIMEOUT`. If you pass
your own `http_client:` (a pre-built `Faraday::Connection`),
`timeout`/`verify`/`proxy` are ignored — your Faraday is used as-is.

### Retry — opt-in via Faraday middleware

Neither `supabase-py` (`storage3`) nor `supabase-rb` retries storage
requests automatically. In Ruby, the idiomatic way to add retries is to
inject a Faraday connection with the [`faraday-retry`][faraday-retry]
middleware:

```ruby
require "faraday"
require "faraday/retry"
require "faraday/follow_redirects"
require "faraday/multipart"
require "supabase/storage"

http = Faraday.new(url: "https://project.supabase.co/storage/v1/") do |f|
  f.request :retry,
            max:            2,
            interval:       0.5,
            backoff_factor: 2,
            retry_statuses: [429, 500, 502, 503, 504],
            # Defaults cover Faraday::TimeoutError + Errno::ETIMEDOUT +
            # Faraday::RetriableResponse — listing them explicitly keeps the
            # set intact when we also want ConnectionFailed.
            exceptions:     [Faraday::ConnectionFailed, Faraday::TimeoutError,
                             Errno::ETIMEDOUT, Faraday::RetriableResponse]
  # Keep the middleware stack the built-in Storage client wires up:
  f.request :multipart                   # bucket.upload(...)
  f.response :follow_redirects           # signed-URL / presigned-upload 30x flow
  f.options.timeout      = 30
  f.options.open_timeout = 30
  f.adapter Faraday.default_adapter
end

storage = Supabase::Storage::Client.new(
  base_url:    "https://project.supabase.co/storage/v1",
  headers:     { "apikey" => key, "Authorization" => "Bearer #{token}" },
  http_client: http
)

storage.list_buckets   # automatically retried on 5xx / network errors
```

`faraday-retry` is not a runtime dependency of `supabase-rb`; add
`gem "faraday-retry"` to your `Gemfile` if you want this pattern.

By default `faraday-retry` only retries idempotent methods (`%i[delete
get head options put]`), which is the right policy for storage: `GET`
list/download, `PUT` upload-overwrite, and `DELETE` remove are safe to
replay. `POST` (`bucket.upload` to a fresh object, `create_bucket`,
`empty_bucket`) is **not** retried by default — opt in via `methods:` if
you understand the duplicate-write tradeoff.

[faraday-retry]: https://github.com/lostisland/faraday-retry
