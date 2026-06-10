# Changelog

All notable changes to this project will be documented in this file. Versions
follow [Semantic Versioning](https://semver.org/). The Ruby port tracks
feature parity with [supabase-py](https://github.com/supabase/supabase-py); see
that project's CHANGELOG for the historical upstream context behind each port.

## [Unreleased]

### Changed (breaking)

- **`Supabase::Functions::Client#invoke` no longer accepts the `method:` or
  `query:` kwargs.** Both existed only to mirror the supabase-js surface
  and had no counterpart in supabase-py — keeping them was a long-running
  source of JS-vs-Py drift in the Ruby client (US-030 / F-C11 part 5).
  Calling `invoke(name, method: "GET")` or `invoke(name, query: {...})`
  now raises `ArgumentError: unknown keyword: :method` (or `:query`) at
  the Ruby kwargs layer — no silent ignore. The method is always `POST`.
  Region routing still appends `forceFunctionRegion=<region>` to the
  query string internally; that path is unchanged. **Migration:**
  - If you were passing `method:` for anything other than the
    pre-existing default `"POST"`, those calls were never going to reach
    a real Edge Function endpoint anyway (Supabase Edge Functions are
    POST-only on the relay side) — remove the kwarg.
  - If you were passing `query:` to attach a query string, append it to
    the function name yourself: `invoke("fn?tenant=x", ...)`.
- **`Supabase::Functions::Client#invoke` no longer auto-parses JSON based
  on the response `Content-Type` header.** Previously a response with
  `Content-Type: application/json` was parsed into a Hash/Array
  automatically; the only way to receive the raw bytes was to use a
  non-JSON Content-Type. From this release the default is *always* the raw
  response body (a `String`) — JSON parsing happens **only** when the
  caller passes `response_type: :json` (or `"json"`). This matches
  supabase-py's contract; it deliberately diverges from supabase-js, which
  sniffs Content-Type. **Migration:** add `response_type: :json` at every
  call site that previously relied on the auto-parse. If you want the raw
  body, the call is now a no-op change.
- **`Supabase::Functions::Client#invoke` now returns the parsed body
  directly instead of the `Types::Response` wrapper.** Previously, every
  invocation returned a `Types::Response` struct exposing `data` / `status`
  / `headers`; callers had to write `client.functions.invoke("hello").data`
  to reach the payload, diverging from supabase-py
  (`client.functions.invoke("hello")` returns the body). From this release
  the bare body — `Hash` / `String` / `Array` / `nil` depending on the
  Content-Type — is the default return value. **Migration:** drop the
  trailing `.data`, or pass `return_response: true` to opt back into the
  legacy wrapper for one more release. `Types::Response` itself is now
  deprecated and emits a one-time `Kernel.warn` on first construction
  (whether built directly or via `return_response: true`); it will be
  removed in a future release.
- **`Supabase::Auth::Client#sign_up` now requires `password` when either
  `email` or `phone` is supplied.** Previously, calling
  `sign_up(email: "x@y.z")` without a password silently posted
  `{ email: "...", password: nil, ... }` to `POST /signup`, where GoTrue
  rejected it with a generic 4xx error. From this release it raises
  `Supabase::Auth::Errors::AuthInvalidCredentialsError` locally — paritetно
  с `gotrue_client.py:283-286`. **Migration:** if you relied on the old
  shape as a "passwordless / magic link" path (it never actually was —
  the server just returned an error), switch to
  `client.auth.sign_in_with_otp(email: "x@y.z")` for magic-link delivery,
  or pass a real password.
- **`Supabase::Realtime::Client#channel(topic)` always returns a new
  Channel instance.** Previously the client memoized channels by topic
  (`@channels[full_topic] ||= Channel.new(...)`), so a second
  `client.channel("public:users")` returned the first instance. That
  diverged from supabase-py, where the channel registry is a flat list
  and every `channel()` call constructs a fresh subscription. From this
  release the Ruby client matches: each call returns a brand-new
  Channel, and `get_channels` may return multiple channels sharing one
  topic. **Migration:** if your code relied on the memoization to fetch
  an existing channel, switch to
  `client.get_channels.find { |c| c.topic == "realtime:public:users" }`.
  Each Channel still owns its own `join_push.ref` and lifecycle, so
  `subscribe → remove_channel → channel(topic)` now yields a new
  instance with a new ref instead of resurrecting the dead one.
- **Storage path segments are now percent-encoded per RFC 3986 (unreserved
  set) instead of `application/x-www-form-urlencoded`.** Previously
  `Supabase::Storage::Utils.encode_segments` delegated to
  `URI.encode_www_form_component`, which encodes spaces as `+` and leaves a
  literal `+` untouched — so `bucket.upload("my file.png", ...)` hit
  `/object/<bucket>/my+file.png` on the server, diverging from
  supabase-py (which uses `yarl`, RFC 3986). Now: space → `%20`,
  `+` → `%2B`, `/` → `%2F`, multi-byte UTF-8 encoded byte-by-byte.
  **Breaking for callers that were compensating for the old bug** —
  e.g. passing `"my+file.png"` to mean "literal plus on the server"
  will now hit `/object/<bucket>/my%2Bfile.png` instead of
  `/object/<bucket>/my+file.png`. If you were intentionally relying on
  the form-urlencoded behavior (passing `"my+file.png"` to get a
  server-side `+`), pass the literal character instead — encoding is
  now done correctly for you. Affects every Storage method that takes a
  `path:` argument (upload / update / download / exists? / info /
  create_signed_url / create_signed_upload_url / upload_to_signed_url /
  get_public_url).
- **`Supabase::Client#set_auth` no longer resets the memoized `auth`
  sub-client.** Previously, calling `set_auth(token)` (or
  `set_auth(nil)` for sign-out) nilled `@auth` alongside the other
  sub-clients, which silently discarded the in-memory persisted session
  held by the auth client's storage backend — so `client.auth.get_session`
  began returning `nil` after any token swap. From this release,
  `set_auth` only rewrites the shared `Authorization` header and resets
  the Postgrest/Storage/Functions sub-clients (Realtime still receives
  `set_auth(token)`). To clear auth state on sign-out, call
  `client.auth.sign_out` — `set_auth(nil)` is no longer a sign-out
  shortcut. The public `set_auth` and the previously-private
  `propagate_auth` (used by the `on_auth_state_change` listener) now
  share a single internal path.

### Removed (breaking)

- **`Supabase::Realtime::Errors::NotConnectedError`,
  `Supabase::Realtime::Errors::AuthorizationError`,
  `Supabase::Realtime::Errors::PushTimeoutError`** — all three were
  declared but never raised anywhere in the codebase, mirroring
  supabase-py's removal of the same dead aliases. The umbrella
  re-exports `Supabase::NotConnectedError` and
  `Supabase::AuthorizationError` are removed alongside them. Callers
  rescuing these names should switch to the base
  `Supabase::Realtime::Errors::RealtimeError`.

## [3.1.1] — Remaining P1 + MISSING parity gaps

Wraps up the remaining items from the supabase-py audit. All additions
are backwards-compatible; only new public APIs and a URL validation on
`Realtime::Client.new`.

### Added

- **`Postgrest::Client#auth(token, username:, password:)`.** Bearer or
  Basic auth on the same method; Bearer wins when both supplied. Raises
  `ArgumentError` if neither is provided. Mirrors supabase-py.
- **`Postgrest::Client#close` + `Postgrest::Client.open(...) { |c| ... }`.**
  `close` releases the memoized Faraday connection; the block form
  yields and closes — moral equivalent of py's `with SyncPostgrestClient(...)`.
- **`Realtime::Channel#push_event(event, payload, timeout:)`** — public
  low-level push for arbitrary Phoenix events. Returns the `Push`
  instance so callers can attach `receive(:ok / :error / :timeout)`.
  (Named `push_event` to avoid shadowing the existing private `send_push`.)
- **`Realtime::Errors::NotConnectedError`** and
  **`Realtime::Errors::AuthorizationError`** — both were referenced from
  the meta-level `Supabase::AuthorizationError` / `Supabase::NotConnectedError`
  aliases but never actually defined. Now the aliases resolve.
- **`Realtime::Transformers.is_ws_url`** and URL scheme validation in
  `Realtime::Client.new` (accepts ws/wss/http/https, raises
  `ArgumentError` otherwise).
- **`Storage::Types::SignedUploadURL#signedURL`** alias (all-caps URL,
  matching supabase-py's TypedDict key) alongside the existing
  `signed_url` / `signedUrl`.
- **`Supabase::Client.create(supabase_url:, supabase_key:, options:)`**
  class method. Builds the client, then — if no explicit `Authorization`
  was passed via `options` — tries to pull a persisted session from
  `client.auth.get_session` and applies its `access_token`. Errors
  during pull are swallowed silently. Mirrors supabase-py's
  `Client.create()`.
- **Auto `on_auth_state_change` listener on `Supabase::Client#auth`.**
  When the auth client emits `SIGNED_IN` / `TOKEN_REFRESHED` /
  `SIGNED_OUT`, the meta client now forwards the new token to every
  other sub-client (Postgrest, Storage, Functions, Realtime) via
  `propagate_auth(token)`. Matches py's `_listen_to_auth_events`.
- **`Auth::Client#bootstrap`** alias for `init(url:)`.

### Fixed

- **`Auth::Client#_save_session`** now serializes the entire `Session`
  struct recursively (Time/Date → iso8601, nested Structs walked)
  instead of cherry-picking allow-listed fields. Custom upstream fields
  on `User` / `Identity` / `Factor` now round-trip through storage
  without being silently dropped. Mirrors py's `model_dump_json()`.

## [3.1.0] — P1 parity polish (Storage, Functions, Realtime, Meta)

Tightens API parity with `supabase-py` for snippets that copy between
languages. The auto-prefix on `client.channel(topic)` and the
`Supabase::Client#schema(name)` immutability are the two visible behavior
changes; the rest are additive aliases and option support.

### Behavior changes

- **`Realtime::Client#channel(topic)` auto-prefixes `"realtime:"`.**
  `client.channel("public:users")` and `client.channel("realtime:public:users")`
  now both reach the same channel. Pre-prefixed topics are detected and left
  alone.
- **`Supabase::Client#schema(name)` is immutable.** Returns a scoped
  `Postgrest::Client` without mutating self — matches supabase-py.
  Previously the call swapped `@postgrest` in place and returned `self`.
- **`Realtime::Client` heartbeat clamps to 15s minimum.** Interval values
  below 15s are treated as 15s in the background loop (matches
  `supabase-py`'s `max(hb_interval, 15)`). `heartbeat_interval: 0` still
  disables the loop.

### Added

- **`Storage::FileApi#download(path, transform:)`.** Image transform options
  route the request through `render/image/authenticated/...`, mirroring
  `supabase-py`'s `DownloadOptions`.
- **`Realtime::Channel#on_presence_sync / on_presence_join /
  on_presence_leave`** and `Channel#presence_state`. Delegates to the
  underlying `Presence` object; if the channel is already joined when the
  first presence callback is attached, the channel auto-resubscribes so the
  server starts emitting presence_state / presence_diff frames.
- **`config.presence.enabled` is now set to `true`** in the join payload
  whenever any presence callback is registered on the channel.
- **`Postgrest::Client#from_` and `Storage::Client#from_`** aliases —
  pasted-from-py snippets like `postgrest.from_("users")` work as-is.
- **`Functions::Types::FunctionRegion`** PascalCase aliases (`UsEast1`,
  `ApSoutheast1`, `EuWest1`, …) alongside the existing `US_EAST_1` constants.
- **`Realtime::Client#close`** alias for `disconnect`.
- **`Auth::Types::AMREntry` objects** returned from
  `mfa.get_authenticator_assurance_level` — was a raw `Hash` array.

### Fixed

- **`Storage::FileApi#upload_to_signed_url`** — `UploadResponse.path` was
  built from `segments[2..]`, which yielded `"sign/<bucket>/<path>"` for
  signed uploads instead of just `<path>`. The relative path is now passed
  explicitly.

## [3.0.0] — Realtime + Auth parity with supabase-py

**Breaking.** Two Realtime behaviors change shape to match `supabase-py` and
`phoenix.js`. Anyone consuming the old shapes needs to update call sites.

### Breaking changes

- **`Realtime::Presence` state and callbacks.** State is now stored as
  `{ key => [{ "presence_ref" => ..., ...data }, ...] }` instead of the raw
  Phoenix wire format `{ key => { "metas" => [...] } }`. Wire payloads are
  transformed via `Presence.transform_state` before being stored or emitted.
  `on_join` / `on_leave` callbacks now receive `(key, current_presences,
  new_presences)` (was `(key, presence_hash)`).
- **`Realtime::Channel#unsubscribe` is ack-based.** State stays in `LEAVING`
  until the server's `phx_reply` lands (or the leave push times out); only
  then does it move to `CLOSED` and fire `on_close` listeners. Code that
  asserted `channel.closed?` synchronously after `unsubscribe` must now wait
  for the ack.

### Added

- **`Realtime::Push#start_timeout`.** Pushes now arm a timer when they go on
  the wire; if no reply arrives within the configured window the push
  resolves with `AckStatus::TIMEOUT` and removes itself from the channel's
  `pending_pushes` registry. `resolve` / `time_out` are mutex-guarded so a
  late ack cannot double-fire callbacks.
- **`Realtime::Client#push` send buffer.** Frames pushed before the socket
  connects are queued and flushed in `handle_socket_open`, matching
  `supabase-py`'s `send_buffer`. Offline pushes are no longer silently
  dropped.
- **`Realtime::Channel#subscribe` postgres_changes mismatch detection.** The
  server's reply to `phx_join` is now diffed against the local
  `on_postgres_changes` callbacks. A mismatch triggers an automatic
  `unsubscribe` and the subscribe callback fires with `CHANNEL_ERROR` plus a
  `Realtime::Errors::RealtimeError` — instead of silently subscribing to a
  different set of rows than requested.
- **`Auth::Errors::UserDoesntExist`.** New exception class, raised by
  `Client#set_session` and `Client#exchange_code_for_session` when
  `get_user(access_token)` returns `nil` — mirrors `supabase-py`'s
  `UserDoesntExist`.

### Fixed

- **`Auth::Helpers.handle_exception` Cloudflare codes.** HTTP 520, 521,
  522, 523, 524, and 530 now produce `AuthRetryableError` (previously only
  502/503/504). Users behind Cloudflare-fronted deployments will now see
  proper retry behavior for upstream-origin failures.

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
