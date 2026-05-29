# Changelog

All notable changes to this project will be documented in this file. Versions
follow [Semantic Versioning](https://semver.org/). The Ruby port tracks
feature parity with [supabase-py](https://github.com/supabase/supabase-py); see
that project's CHANGELOG for the historical upstream context behind each port.

## [Unreleased]

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
