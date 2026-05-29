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
