# Changelog

All notable changes to this project will be documented in this file. Versions
follow [Semantic Versioning](https://semver.org/). The Ruby port tracks
feature parity with [supabase-py](https://github.com/supabase/supabase-py); see
that project's CHANGELOG for the historical upstream context behind each port.

## [0.1.3](https://github.com/supabase-ruby/supabase-rb/compare/v0.1.2...v0.1.3) (2026-05-29)


### Bug Fixes

* **realtime:** server-side postgres_changes, auto heartbeat, auto reconnect ([0032791](https://github.com/supabase-ruby/supabase-rb/commit/0032791d8828632cfdd35b7d669e2d19935e0a4a))

## [Unreleased]

## [2.0.0] — Single fat gem

**Breaking.** `supabase-rb` is now a single self-contained gem packaging Auth,
PostgREST, Storage, Edge Functions, and Realtime. The previous meta-gem layout
(`supabase-rb` 1.0.0 depending on `supabase-auth`/`-postgrest`/`-storage`/
`-functions`/`-realtime` sub-gems) is gone, along with the five sub-gemspecs.
`supabase-auth` 0.x has been yanked from RubyGems. The Ruby API (`require
"supabase"`, `Supabase.create_client`, all module classes) is unchanged.

## [1.0.0] — Umbrella renamed to `supabase-rb`

The umbrella gem is now published as `supabase-rb` (the bare `supabase` name on
RubyGems belongs to an unrelated project). The Ruby require path is unchanged
(`require "supabase"`), as is the `Supabase` module and `Supabase.create_client`
factory. Sub-gem names (`supabase-auth`, `supabase-postgrest`, `supabase-storage`,
`supabase-functions`, `supabase-realtime`) are unchanged.

### Added

- Top-level `Supabase::ClientOptions` struct mirroring supabase-py's
  `ClientOptions` / `AsyncClientOptions` dataclasses, including a `#replace`
  method for derivation and a `#to_h` round-trip.
- Top-level `Supabase.acreate_client` / `Supabase.create_async_client` factories
  matching supabase-py's async aliases.
- Top-level error re-exports (`Supabase::StorageException`,
  `Supabase::PostgrestAPIError`, `Supabase::AuthApiError`,
  `Supabase::FunctionsHttpError`, `Supabase::AuthorizationError`, …) so callers
  can rescue with the umbrella names.
- `Supabase::SupabaseException` for url/key validation, raised by
  `Supabase::Client#initialize` to match supabase-py's contract.
- `Supabase::Storage::AnalyticsClient` (iceberg bucket management) accessible
  via `client.storage.analytics`.
- `Supabase::Storage::VectorsClient` + `VectorBucketScope` + `VectorIndexScope`
  for vector bucket / index / record management via `client.storage.vectors`.
- `Supabase::Storage::Errors::VectorBucketException` for client-side validation
  (batch-size bounds, etc.).
- `Supabase::Realtime::Transformers.http_endpoint_url` helper porting
  `realtime/transformers.py`.

## [0.1.0] — Initial public port

Initial Ruby port covering all six supabase-py modules: `auth`, `postgrest`,
`storage`, `functions`, `realtime`, and the top-level `supabase` umbrella.
