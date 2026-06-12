# Parity Tracker: supabase-rb ↔ supabase-py

**Standard (revised 2026-06-12): production-ready, supabase-py as REFERENCE — do NOT
carry py's bugs.** py defines the API shape, capability set, defaults, and naming. But
where py has a clear bug, typo, or footgun, supabase-rb does the *correct* thing instead of
reproducing it. When "correct" is ambiguous, **supabase-js is the tie-breaker** — it is the
canonical Supabase client and the real source of truth for wire protocol and server
behavior; py itself lags js in places.

Consequences for this tracker:
- 🔧 rows ("rb fixes py bug") are **CORRECT and kept** — they just need a
  `# DIVERGES FROM PY (intentional): py does X (bug); we do Y` comment so the divergence is
  auditable. They are no longer "violations".
- 🐞 rows ("rb wrong vs py") are still **bugs to fix** — rb diverged in the wrong direction.
- A new category emerges: **py-bug-faithfully-ported** — places rb copied a py bug. These
  are now **fix targets** (the whole point of this standard). Tagged 🐍 below.

Legend:

- ✅ **OK** — matches py (or matches js where py is wrong)
- 🟰 **signature differs** — same capability, idiomatic Ruby signature (kwargs/blocks); fine
- ⚠️ **behavior differs** — runtime behavior diverges; assess against js, fix if rb is worse
- ❌ **missing** — no Ruby counterpart
- 🔧 **rb fixes py bug** — KEEP, document as intentional divergence
- 🐞 **rb bug vs py** — fix: rb diverged in the wrong direction
- 🐍 **py bug ported into rb** — fix: rb faithfully reproduced a py bug we don't want

Line refs use `py_path:line ↔ rb_path:line`. Paths are relative to each package root:
- py: `supabase-py/src/<pkg>/src/...`
- rb: `supabase-rb/lib/supabase/...`

Reviewed against: supabase-rb `VERSION = 3.2.0`. Review date: 2026-06-12.

---

## 0. Executive parity status

| Module | Surface parity | Behavior parity | Blocking items |
|---|---|---|---|
| postgrest | ~100% | high | redirects FIXED; C-PG-5/8/9 minor open |
| storage | ~100% | high | upload(String)=bytes documented as intentional; vectors snake_case FIXED |
| functions | 100% | high | x-relay + json FIXED; header-leak kept (intentional) |
| auth | ~95% | high | error masking FIXED; get_claims aligned py-1:1 (no leeway, sig-only); no `close` open |
| realtime | ~95% | high | D1 blocker + D2/D3/D4/D5/D6/D8 FIXED; D7 resolved-intentional; D9 open |
| top-level client | 100% + extras | high | C-TL-3 lazy-realtime token FIXED; C-TL-1 reclassified not-a-bug |

**Overall: approaching production-grade.** Under the revised standard (production-ready, py
as reference, no py bugs), two fix batches landed 2026-06-12:
- **Batch 1 (realtime):** D1 (access_token placement — the blocker) + D2/D3/D4/D6/D8.
- **Batch 2 (cross-module):** functions `x-relay-error` (🐍) + `:json` raises on bad JSON
  (🐞); auth error-masking (🐞); storage vectors `list_indexes`
  camelCase (🐍); follow-redirects wired into postgrest/auth/functions (storage already had
  it); upload(String)=bytes documented as an intentional js-aligned divergence.

Suite status (2026-06-12): **2291 examples, 0 failures, 0 pending** with both stacks up
(GoTrue compose in `infra/` + a full local Supabase stack via `supabase start` for realtime).
Without the integration stack the 5 realtime specs self-skip (pending), and without the GoTrue
compose the 57 live auth specs fail with ECONNREFUSED — neither is a code problem.

Running the live suite revealed two REAL realtime bugs that the mocked specs could not (logged
as D-LIVE-1/2 in §0b): a duplicate join when `subscribe()` runs before the socket finishes
opening (the server phx_closed the dup and delivery silently broke), and `remove_all_channels`
not closing the socket. Both are fixed; all 5 realtime integration specs (broadcast, presence,
postgres_changes INSERT/UPDATE/DELETE, teardown) now pass against a live Supabase Realtime
server. The EdDSA spec was un-gated by adding `rbnacl` (+ system `libsodium`) as a soft dev
dep, which also surfaced/fixed the `ED25519`-vs-`EdDSA` alg-name issue. Remaining open items:
realtime D9 (D5 fixed 2026-06-12), and assorted minor rows. See §6, §9.

**Running the live suite locally:** `cd infra && docker compose up -d` brings up four GoTrue
servers (ports 9999/9998/9997/9996), Postgres, and inbucket mail; then `bundle exec rspec`.
`docker compose down` to stop.

---

## 0b. Fix log (2026-06-12)

| Item | Class | Module | What changed | Spec |
|---|---|---|---|---|
| D1 | 🐞 blocker | realtime | access_token → join-payload root, omitted when nil | us008 (rewritten) |
| D2/D8 | 🐞/⚠️ | realtime | phx_error & system-error → ERRORED + rejoin | us018 |
| D3 | 🐞 | realtime | set_auth buffers offline via push_access_token | us018 |
| D4 | 🐞 | realtime | unsubscribe/phx_close removes channel from registry | us018 |
| D6 | 🐞 | realtime | heartbeat error → reconnect; wire socket.on_error | (covered) |
| C-FN relay | 🐍 | functions | x-relay-header → x-relay-error (per js) | us028, client_spec |
| C-FN-1 | 🐞 | functions | :json + bad body raises instead of raw String | us027 |
| C-Auth-1 | 🐞 | auth | AuthError from xform no longer masked as retryable | get_claims_error_masking_and_leeway |
| C-Auth-2 | ✅ py-1:1 | auth | get_claims aligned to py: exp check with no leeway, signature-only verify (nbf/iss/aud not validated) | get_claims_error_masking_and_leeway |
| vectors keys | 🐍 | storage | list_indexes sends camelCase nextToken/maxResults | vectors_spec |
| C-PG-2 | ⚠️ | postgrest/auth/functions | follow_redirects middleware wired in | follow_redirects_spec |
| C-ST-1 | ⚖️ | storage | upload(String)=bytes — documented intentional (js-aligned) | (doc only) |
| C-TL-3 | 🐞 | top-level | lazy-built realtime seeds access_token from current token, not anon key | lazy_realtime_token_spec |
| C-TL-1 | ✅ reclassified | top-level | NOT a bug — see note below; no change needed | lazy_realtime_token_spec |
| D-LIVE-1 | 🐞 | realtime | duplicate join when subscribe() runs before the socket finishes opening (buffer-flush + rejoin both sent it) → server phx_closed the dup → delivery broke. Fixed: join sent exactly once; Client#connect made idempotent (`@connecting`) | realtime_live_spec (live) |
| D-LIVE-2 | 🐞 | realtime | remove_all_channels didn't close the socket (py `self.close()` does); remove_channel's empty-branch close triggered a reconnect. Fixed: both use the intentional-close path | realtime_live_spec, us019 |
| EdDSA | 🐞 | auth | get_claims rejected real EdDSA tokens — spec had used ruby-jwt's deprecated `ED25519` alg name; standard `EdDSA` (RFC 8037) verifies end-to-end via OKP JWKS | get_claims_algorithms_spec |
| P0 token-in-URL | 🐞 | realtime | `access_token` was serialized into the ws URL query (umbrella passes it in params; URLs get logged by proxies). py sends only `apikey` in the URL (client.py:78-79); js likewise carries the token in joins/pushes. `normalize_url` now drops `access_token` + nil params; token still flows via join payload / set_auth | client_spec (URL normalization) |
| P0 buffered push | 🐞 | realtime | a push buffered on a never-joining channel hung forever (timeout armed only on wire-send). py arms it at queue time (channel.py:318-323). Now armed at queue time; flush skips already-resolved (timed-out) pushes so they don't hit the wire late | channel_spec ("push timeout while buffered") |
| P0 analytics apiKey | 🐞 | storage | `analytics.catalog` read `@headers["apiKey"]` case-sensitively; umbrella sends lowercase `"apikey"` → always raised. py uses case-insensitive httpx.Headers. Lookup now case-insensitive (exact `apiKey` wins if both present) | analytics_spec |
| P0 async admin redirects | 🐞 | auth | `Async::AdminApi#build_connection` omitted `follow_redirects` (sync Api/AdminApi and Async::Api all have it) — async admin requests didn't follow 3xx | async/admin_api_spec |

**C-TL-1 reclassification (2026-06-12):** originally flagged as "umbrella doesn't refresh the
auth client's bearer after a token change." On tracing, this is **not a real bug** and needs
no fix: the auth client passes `jwt: session.access_token` explicitly on every user-scoped
call (get_user/update_user/reauthenticate/link/unlink), and `Api#_request` overrides
Authorization when a jwt is present — so user calls always use the **live session token**, not
the static `@headers`. Admin calls use the construction-time service key (stable, correct),
and public/non-jwt calls (sign_in/up/refresh) correctly keep the anon key. supabase-js also
does NOT re-inject the token into its auth (GoTrue) client. py's
`self.auth._headers["Authorization"] = ...` is a py quirk we intentionally don't carry.

---

## 1. Auth

py root: `auth/src/supabase_auth/` · rb root: `auth/`

### 1.1 SyncGoTrueClient ↔ `Supabase::Auth::Client`

| python_method | ruby_method | status | note |
|---|---|---|---|
| `__init__(url=None, ..., flow_type="implicit", verify=True, proxy)` (`_sync/gotrue_client.py:101`) | `initialize(url:, headers: {}, **options)` (`client.rb:54`) | ⚠️ | Ruby `url:` required, no `GOTRUE_URL` fallback (`gotrue_client.py:136`). py defaults `flow_type="implicit"` — confirm rb default matches. |
| `initialize(url=None)` (`:176`) | `init` / `bootstrap` (`client.rb:89`) | ✅ | rename forced by ctor name |
| `initialize_from_storage()` (`:182`) | `initialize_from_storage` (`client.rb:99`) | ✅ | |
| `initialize_from_url(url)` (`:185`) | `initialize_from_url` (`client.rb:672`) | ✅ | |
| `sign_in_anonymously(credentials=None)` (`:199`) | `sign_in_anonymously` (`client.rb:415`) | ✅ | |
| `sign_up(credentials)` (`:227`) | `sign_up` (`client.rb:113`) | ⚠️ 🔧 | rb adds "password required" error + `redirect_to` alias py lacks |
| `sign_in_with_password(credentials)` (`:294`) | same (`client.rb:165`) | ✅ | error message text differs |
| `sign_in_with_id_token(credentials)` (`:346`) | same (`client.rb:440`) | ✅ | |
| `sign_in_with_sso(credentials)` (`:381`) | same (`client.rb:472`) | ✅ | |
| `sign_in_with_oauth(credentials)` (`:438`) | same (`client.rb:509`) | ✅ | |
| `link_identity(credentials)` (`:461`) | same (`client.rb:617`) | ✅ | |
| `get_user_identities()` (`:488`) | same (`client.rb:323`) | ✅ | |
| `unlink_identity(identity)` → `httpx.Response` (`:494`) | same → Hash (`client.rb:640`) | ⚠️ | py returns raw Response; rb returns parsed Hash. Ported py code expecting Response breaks. |
| `sign_in_with_otp(credentials)` (`:505`) | same (`client.rb:203`) | ✅ | `should_create_user` default true both |
| `resend(credentials)` (`:577`) | same (`client.rb:527`) | ✅ | |
| `verify_otp(params)` (`:612`) | same (`client.rb:248`) | ⚠️ | py spreads `**params` incl. `options` key; rb builds explicit body. Server ignores extras. |
| `reauthenticate()` (`:634`) | same (`client.rb:557`) | ✅ | |
| `get_session()` (`:646`) | same (`client.rb:283`) | ✅ | EXPIRY_MARGIN identical |
| `get_user(jwt=None)` (`:676`) | `get_user(jwt = nil)` (`client.rb:307`) | ✅ | |
| `update_user(attributes, options=None)` (`:691`) | same (`client.rb:589`) | ✅ | py mutates session.user; rb builds new struct — same effect |
| `set_session(access_token, refresh_token)` (`:714`) | same (`client.rb:338`) | ⚠️ 🔧 | py `IndexError` on tokenless ".", rb guards `length > 1`. rb more robust on malformed input. |
| `refresh_session(refresh_token=None)` (`:762`) | same (`client.rb:383`) | ✅ | |
| `sign_out(options=None)` (`:779`) | same (`client.rb:397`) | ✅ | scope "global" default both |
| `on_auth_state_change(callback)` (`:800`) | `on_auth_state_change(&callback)` (`client.rb:653`) | 🟰 | block instead of callable |
| `reset_password_for_email(email, options=None)` (`:820`) | same (`client.rb:568`) | ✅ | py None / rb Hash return |
| `reset_password_email(...)` (`:839`) | `reset_password_email(email:, **options)` (`client.rb:581`) | ⚠️ | rb keyword-only — positional call raises |
| `exchange_code_for_session(params)` (`:1185`) | same (`client.rb:755`) | ✅ | |
| `get_claims(jwt=None, jwks=None)` (`:1242`) | `get_claims(jwt: nil, jwks: nil)` (`client.rb:688`) | ⚠️ 🐞 | keyword-only + verification semantics differ — see C-Auth-2/3 |
| `close()` / `__enter__`/`__exit__` (`gotrue_base_api.py:32`) | — | ❌ | no resource mgmt / block form |
| `__del__` (`:1287`) | — | ❌ | no finalizer; refresh timer thread leaks until `_remove_session` |

### 1.2 MFA API ↔ `MFAApi` (`client.rb:1095`)

| python | ruby | status | note |
|---|---|---|---|
| `mfa.enroll(params)` (`gotrue_mfa_api.py:852`) | `enroll` (`client.rb:1104`) | ✅ | rb skips py's "phone required" pydantic validation |
| `mfa.challenge(params)` (`:880`) | `challenge` (`client.rb:1132`) | ✅ | |
| `mfa.challenge_and_verify(params)` (`:892`) | same (`client.rb:1173`) | ⚠️ | rb forwards `:channel`; py never does (additive) |
| `mfa.verify(params)` (`:909`) | `verify` (`client.rb:1147`) | ⚠️ 🐞 | py raises if response not full Session; rb silently skips save when no `access_token` → `MFA_CHALLENGE_VERIFIED` may not fire |
| `mfa.unenroll(params)` (`:925`) | same (`client.rb:1188`) | ✅ | |
| `mfa.list_factors()` (`:936`) | same (`client.rb:1201`) | ✅ | |
| `mfa.get_authenticator_assurance_level()` (`:947`) | same (`client.rb:1217`) | ✅ | rb `.compact`s invalid AMR; py raises |

### 1.3 Admin API ↔ `AdminApi` (`admin_api.rb`)

| python | ruby | status | note |
|---|---|---|---|
| `sign_out(jwt, scope="global")` (`gotrue_admin_api.py:70`) | `sign_out(access_token, scope="global")` (`admin_api.rb:107`) | ✅ | |
| `invite_user_by_email(email, options=None)` (`:82`) | same (`admin_api.rb:97`) | ✅ | |
| `generate_link(params)` (`:99`) | same (`admin_api.rb:80`) | ✅ | |
| `create_user(attributes)` (`:120`) | same (`admin_api.rb:31`) | ✅ | |
| `list_users(page=None, per_page=None)` → `List[User]` (`:134`) | `list_users(page:, per_page:)` (`admin_api.rb:40`) | 🟰 | rb kwargs; missing "users" → py raises, rb `[]` |
| `get_user_by_id(uid)` (`:150`) | same (`admin_api.rb:53`) | ✅ | py `ValueError` / rb `ArgumentError` on bad UUID |
| `update_user_by_id(uid, attributes)` (`:165`) | same (`admin_api.rb:64`) | ✅ | |
| `delete_user(id, should_soft_delete=False)` (`:184`) | `delete_user(uid, should_soft_delete: false)` (`admin_api.rb:74`) | 🟰 | rb keyword |
| `mfa.list_factors(params)` → bare `List[Factor]` (`:195`) | `mfa.list_factors(user_id:)` → wrapper Struct (`admin_mfa_api.rb:17`) | ⚠️ 🐞 | **return shape differs**: py iterates list, rb needs `.factors`. Ported py code breaks. |
| `mfa.delete_factor(params)` (`:206`) | `delete_factor(user_id:, id:)` (`admin_mfa_api.rb:25`) | 🟰 | kwargs |
| `oauth.list_clients(params=None)` (`:218`) | same (`admin_oauth_api.rb:16`) | ✅ | pagination header parsing replicated |
| `oauth.create_client(params)` (`:263`) | same (`admin_oauth_api.rb:22`) | ✅ | |
| `oauth.get_client(client_id)` (`:282`) | same (`admin_oauth_api.rb:28`) | ✅ | |
| `oauth.update_client(client_id, params)` (`:300`) | same (`admin_oauth_api.rb:35`) | ✅ | |
| `oauth.delete_client(client_id)` (`:320`) | same (`admin_oauth_api.rb:40`) | ✅ | |
| `oauth.regenerate_client_secret(client_id)` (`:337`) | same (`admin_oauth_api.rb:46`) | ✅ | |

### 1.4 Auth — critical discrepancies

- **C-Auth-1 (error masking):** `AuthInvalidJwtError` from JWKS xform re-wrapped as
  `AuthRetryableError`. `gotrue_base_api.py:75` ↔ `api.rb:62-65` + `helpers.rb:100-102`.
  Blanket `rescue StandardError` converts any non-Faraday error to retryable status 0.
- **C-Auth-2 (over-verification) ✅ FIXED (py-1:1, 2026-06-12):** rb previously validated
  `exp`/`nbf` via `JWT.decode` defaults plus a 10s leeway. Now matches py exactly:
  manual `validate_exp` with no leeway (`helpers.py:286-292` ↔ `helpers.rb`), and
  `JWT.decode(..., verify_expiration: false, verify_not_before: false)` = signature-only
  verification (`gotrue_client.py:1272-1282` ↔ `client.rb`). Future-`nbf` token now passes
  in both clients; a token expired by 1s is rejected in both.
- **C-Auth-3 (transport retry) 🔧:** py maps only `HTTPStatusError|RuntimeError`; network
  errors fly raw → auto-refresh never retries them. rb maps Faraday timeouts to
  `AuthRetryableError` and *does* retry. `helpers.rb:99-114`.
- **C-Auth-4 (stored session leniency) 🔧:** py full pydantic validation
  (`gotrue_client.py:1139-1151`) ↔ rb checks only `expires_at` (`client.rb:993-1013`).
- **C-Auth-5 (decode_jwt strictness) 🔧:** rb rejects malformed base64url py silently
  decodes. `helpers.py:220-240` ↔ `helpers.rb:20-38`.
- **C-Auth-6 (weak_password) 🔧:** py has dead-code + `KeyError` paths; rb returns
  `AuthWeakPassword` where py returns `AuthApiError`/`AuthUnknownError`.
  `helpers.py:165-184` ↔ `helpers.rb:133-149`.
- **C-Auth-7 (default URL):** py falls back to `http://localhost:9999`; rb requires `url:`.
- **C-Auth-8 (X-Client-Info):** py `supabase-py/...; platform=...`; rb `gotrue-rb/{VERSION}`.

**Verified equal:** EXPIRY_MARGIN=10s, MAX_RETRIES=10, backoff `200*2^(n-1)`ms, auto-refresh
tick, `_call_refresh_token`, `_notify_all_subscribers`, full PKCE flow, JWKS TTL 600s +
lookup order, HS256 → `get_user` fallback. Error hierarchy shape + 82 error codes match
exactly. Network status codes `[502,503,504,520,521,522,523,524,530]` match.

---

## 2. Postgrest

py root: `postgrest/src/postgrest/` · rb root: `postgrest/`

### 2.1 Client ↔ `Supabase::Postgrest::Client`

| python | ruby | status | note |
|---|---|---|---|
| `__init__(base_url, *, schema, headers, timeout, verify, proxy, http_client)` (`_sync/client.py:29`) | `initialize(base_url:, ...)` (`client.rb:41`) | 🟰 | py deprecation-warns timeout/verify/proxy; rb silent |
| `from_(table)` (`:128`) | `from` + `from_` alias (`client.rb:114`) | ✅ | |
| `table(table)` (`:140`) | `alias table from` (`client.rb:118`) | ✅ | |
| `from_table` deprecated (`:144`) | — | ❌ | deprecated alias, OK to omit |
| `schema(schema)` (`:107`) | `schema(name)` (`client.rb:103`) | ⚠️ | both immutable; py builds new session, rb shares injected http_client |
| `rpc(func, params, count, head, get)` (`:149`) | `rpc(func, params={}, count:, head:, get:)` (`client.rb:130`) | ✅ | GET/HEAD→query, POST→body parity |
| `auth(token, *, username, password)` (`base_client.py:37`) | `auth(token, username:, password:)` (`client.rb:60`) | ✅ | **untested in rb (no spec)** |
| `aclose()` / `__enter__`/`__exit__` (`:118`) | `close` / `Client.open` (`client.rb:77`) | ✅ | |

### 2.2 Filters (all present — ✅ unless noted)

`eq neq gt gte lt lte like ilike like_all_of like_any_of ilike_all_of ilike_any_of
fts plfts phfts wfts in_ is_ contains contained_by overlaps range_gt/gte/lt/lte/adjacent
match not_ filter or_ text_search cs cd sl sr nxl nxr adj max_affected` — all map 1:1
(`base_request_builder.py:286-547` ↔ `request_builder.rb:205-327`).

- `or_(filters, reference_table=None)`: py positional, rb keyword-only 🟰
- `is_` boolean rendering: py `is.True`, rb `is.true` — **uncertain** (see §7)

### 2.3 Modifiers / execution

| python | ruby | status | note |
|---|---|---|---|
| `select/insert/upsert/update/delete` (`_sync/request_builder.py:300-446`) | `request_builder.rb:593-639` | ✅ | defaults match (returning=representation, on_conflict, ignore_duplicates, default_to_null) |
| `order/limit/offset/range/single/maybe_single/csv/explain/text_search` (`base_request_builder.py:569+`) | `request_builder.rb:353-535` | ✅ | py `params.add` vs rb assign — minor |
| `execute()` → `APIResponse` (`:78`) | `request_builder.rb:408` | ✅ | attrs `data`, `count` match |
| maybe_single >1 row → APIError code 406 (`:162`) | `request_builder.rb:454` | ✅ | hint wording differs |
| `APIError(message/code/hint/details)` (`exceptions.py:22`) | `Errors::APIError` (`errors.rb:9`) | ✅ | |

### 2.4 Postgrest — critical discrepancies

- **C-PG-1 (retry HEAD) 🔧:** py typo `"HTTP"` → only GET retried (`base_request_builder.py:102`);
  rb retries GET+HEAD (`request_builder.rb:42`). **Under py-1:1: reproduce the GET-only bug
  or document.**
- **C-PG-2 (no redirects/HTTP2) ⚠️:** py `follow_redirects=True, http2=True`
  (`_sync/client.py:103-104`); rb has neither. 3xx → APIError in rb, followed in py.
- **C-PG-3 (timeout) 🔧:** py passes raw `timeout=None` → httpx disables timeouts; documented
  120s never applies (`_sync/client.py:97`). rb always applies 120s (`client.rb:49,177`).
  Under py-1:1: rb requests time out where py hangs forever.
- **C-PG-4 (error parsing strictness) 🔧:** py pydantic requires message/code/hint/details →
  partial error body → generic fallback (`_sync/request_builder.py:95`). rb lenient, keeps real
  message (`errors.rb:13-27`).
- **C-PG-5 (auth after from) ⚠️:** py live Headers ref; rb snapshot `@headers.dup`
  (`client.rb:115`) → `client.auth(token)` after `from()` ignored in rb.
- **C-PG-6 (RPC select query keys):** py duplicate `select=` params; rb comma-joins.
- **C-PG-7 (Content-Range no `/`):** py → None; rb → 0 (`request_builder.rb:148`).
- **C-PG-8 (FlatParamsEncoder footgun):** injected `http_client:` without
  `FlatParamsEncoder` silently breaks repeated same-column filters (`col[]=` vs `col=`).
- **C-PG-9 (header case-sensitivity):** rb plain Hash vs py case-insensitive `httpx.Headers`;
  user `"prefer"` key not merged (`request_builder.rb:328,401,411`).

---

## 3. Storage

py root: `storage/src/storage3/` · rb root: `storage/`

### 3.1 Bucket + file ops

| python | ruby | status | note |
|---|---|---|---|
| `list_buckets/get_bucket/create_bucket/update_bucket/empty_bucket/delete_bucket` (`bucket.py:52-126`) | `bucket_api.rb:25-60` | ✅ / 🟰 | create/update flatten options dict→kwargs |
| `upload(path, file, file_options)` (`file_api.py:574`) | `upload(path, file, content_type:, ...)` (`file_api.rb:47`) | ⚠️ 🐞 | **String semantics inverted — see C-ST-1** |
| `update` (`:596`) | `update` (`file_api.rb:53`) | ✅ | both strip `x-upsert` on PUT |
| `download(path, options, query_params)` (`:459`) | `download(path, transform:, query_params:)` (`file_api.rb:67`) | ✅ | |
| `list(path, options)` (`:417`) | `list(prefix=nil, ...)` (`file_api.rb:86`) | ✅ | DEFAULT_SEARCH_OPTIONS match (limit 100/offset 0/name asc) |
| `list_v2(options)` (`:447`) | `list_v2(...)` (`file_api.rb:104`) | ✅ | |
| `move/copy/remove` (`:316-360`) | `file_api.rb:118-127` | ✅ | rb `Array()`-wraps single remove path |
| `create_signed_url(s)` (`:212-244`) | `file_api.rb:151-166` | ✅ | both return `{signedURL, signedUrl}` |
| `create_signed_upload_url(path, options)` (`:97`) | `file_api.rb:201` | 🟰 | py dict / rb `SignedUploadURL` Struct |
| `upload_to_signed_url` (`:134`) | `file_api.rb:213` | ✅ | |
| `get_public_url(path, options)` (`:289`) | `file_api.rb:186` | ✅ | |
| `info(path)` (`:376`) | `file_api.rb:132` | ✅ | |
| `exists(path)` (`:395`) | `exists?(path)` (`file_api.rb:137`) | ⚠️ | py rescues `JSONDecodeError`, rb rescues `StorageApiError` — same on empty HEAD |
| analytics: `create/list/delete` (`analytics.py:22-50`) | `analytics.rb:27-42` | ✅ | |
| analytics: `catalog(...)` → `RestCatalog` (`:54`) | → config Hash (`analytics.rb:51`) | ⚠️ | no Ruby Iceberg client; rb returns config Hash |
| vectors: bucket/index/put/get/list/query/delete (`vectors.py`) | `vectors.rb:34-177` | ✅ | both send snake_case `next_token`/`max_results` (py bug ported) |

### 3.2 Storage — critical discrepancies

- **C-ST-1 (upload String) 🐞 HIGH UX RISK:** py `str`/`Path` = filesystem path, opened
  (`file_api.py:556-564`); rb `String` = raw bytes, only `Pathname` = path
  (`file_api.rb:292-295`). `upload("a.png", "./local/a.png")` silently uploads the path
  string as content in rb. **Under py-1:1: should match py — String must mean path.**
- **C-ST-2 (RETRY — your focus):** ✅ **parity, neither has retry.** py storage3 has zero
  retry (`_sync/client.py:76-83`, `request.py:24`); rb `request.rb` has zero retry too. The
  `faraday-retry` recipe in rb README is opt-in docs, not runtime behavior. *If you remember
  writing retry — it isn't in the code.*
- **C-ST-3 (multipart header precedence) ⚠️:** py client headers win (`file_api.py:70`); rb
  `send_multipart` per-call headers win (`file_api.rb:268`) — inconsistent even within rb.
- **C-ST-4 (error fallback shape) 🔧:** py hardcodes status 400 / raw `KeyError`; rb unifies
  to `StorageApiError` with real status (`request.rb:39-48`).
- **C-ST-5 (warn_unknown_transform_keys) 🔧:** rb `Kernel#warn` on unknown transform keys
  (`file_api.rb:228`); py forwards silently. New stderr output.
- **Typed-response renames:** `UploadResponse` adds `key`; vectors items mapped to
  `{name:}`/`{index_name:}` vs py `vectorBucketName`/`indexName`. Ported py code reading
  those fields breaks.

**Verified equal:** DEFAULT_FILE_OPTIONS (cache-control 3600, text/plain;charset=UTF-8,
x-upsert false), metadata base64 `x-metadata` + JSON form field, `x-upsert` POST-only,
signed-URL building, path percent-encoding, list defaults, camelCase wire keys.

---

## 4. Functions

py root: `functions/src/supabase_functions/` · rb root: `functions/`

| python | ruby | status | note |
|---|---|---|---|
| `invoke(function_name, invoke_options)` camelCase keys (`_sync/functions_client.py:124`) | `invoke(function_name, body:, headers:, region:, response_type:, ...)` (`client.rb:88`) | 🟰 | rb adds `return_response:` + `Types::Response` shim (no py analogue) |
| function_name validation → ValueError (`:137`) | → ArgumentError (`client.rb:150`) | ✅ | |
| `FunctionRegion` enum 15 values (`utils.py:16`) | `Types::FunctionRegion` (`types.rb:33`) | ✅ | identical strings |
| region → `x-region` + `forceFunctionRegion` (`:154`) | `client.rb:96-99` | ✅ | |
| body str→text/plain, dict→json (`:159`) | String→text/plain, Hash/Array→json (`client.rb:101`) | ⚠️ | rb `\|\|=` keeps caller Content-Type; py overwrites |
| `responseType=="json"` → `.json()` raises on bad JSON (`:173`) | `:json` → `parse_json_safe \|\| body` (`client.rb:193`) | ⚠️ 🐞 | **C-FN-1: rb silently returns raw String on parse failure** |
| relay: `x-relay-header=="true"` → FunctionsRelayError (`:168`) | same (`client.rb:170`) | ✅ | both use `x-relay-header` (js uses `x-relay-error` — py bug ported) |
| non-2xx → FunctionsHttpError (`:98`) | `raise_for_status!` (`client.rb:180`) | ✅ | py fallback msg includes URL; rb doesn't |
| `set_auth(token)` (`:113`) | `client.rb:57` | ✅ | |
| invoke mutates client headers (`:139-163`) | per-call merge (`client.rb:93`) | 🔧 | **C-FN-2: py leaks x-region/Content-Type across calls; rb fixes. Under py-1:1: reproduce or document.** |

---

## 5. Top-level client

py root: `supabase/src/supabase/` · rb root: `supabase.rb`, `client.rb`, `client_options.rb`

| python | ruby | status | note |
|---|---|---|---|
| `create_client(url, key, options)` (`_sync/client.py:349`) | `Supabase.create_client(...)` (`supabase.rb:334`) | 🟰 | rb folds sync/async via `async:` flag |
| url/key validation, regex `^(https?)://.+` (`:56`) | same (`client.rb:67`) | ✅ | |
| access-token resolution (Authorization > session > anon) (`:101`) | same (`client.rb:39`) | ✅ | |
| ClientOptions defaults (schema public, timeouts 120/20/5, flow_type pkce) (`client_options.py:34`) | same (`client_options.rb:24`) | ✅ | |
| `ClientOptions.replace()` — `or`-based, can't set falsy (`:120`) | `to_h.merge` — falsy works (`client_options.rb:61`) | 🔧 | py can't set `persist_session=False` via replace; rb can |
| auth+realtime eager, postgrest/storage/functions lazy (`:87`) | all five lazy (`client.rb:120`) | ⚠️ | **C-TL-3: listener registration timing differs** |
| `_listen_to_auth_events` updates `auth._headers` (`:346`) | `apply_auth` does NOT refresh `@auth` (`client.rb:240`) | 🐞 | **C-TL-1: auth client keeps stale bearer after refresh** |
| non-token events → rewrite Auth to anon key (`:334`) | rb skips other events (`client.rb:128`) | 🔧 | **C-TL-2** |
| sync never sets realtime token; async does (`_async/client.py:348`) | rb always dispatches `set_auth` (`client.rb:243`) | 🔧 | rb = async-py behavior in both modes |
| `table/from_/schema/rpc` delegation (`:128`) | `from` + `alias table` (`client.rb:161`) | ✅ | |
| `channel/get_channels/remove_channel/remove_all_channels` (`:220`) | `client.rb:179` | ✅ | |
| — | public `set_auth(token)` (`client.rb:222`) | ➕ | rb-only superset |
| — | legacy nested-hash options (`client.rb:81`, `legacy_options_hash?` `client.rb:251`) | ➕ | rb-only back-compat. Detector fixed 2026-06-12: only `:auth`/`:postgrest`/`:functions`/`:global` are unambiguous legacy markers; `:storage` disambiguated by value (Hash → legacy sub-kwargs, object → ClientOptions session storage), `:realtime` alone is never a legacy marker. Previously `{ schema:, realtime: {...} }` silently dropped `schema` and `{ storage: <object> }` crashed. Stray flat keys mixed into legacy shape now warn. Spec: `spec/supabase/legacy_options_detection_spec.rb` |

---

## 6. Realtime — ⚠️ LOWEST PARITY, contains the blocker

py root: `realtime/src/realtime/_async/` (the `_sync/*` tree is `NotImplementedError` stubs)
· rb root: `realtime/`

### 6.1 Client

| python | ruby | status | note |
|---|---|---|---|
| `__init__(url, token, ...)` (`client.py:44`) | `initialize(url:, params:, ...)` (`client.rb:53`) | 🟰 | no `token:` kwarg; apikey via params. Defaults match (25s hb, 5 retries, 1.0 backoff, 10s timeout) |
| `connect()` retry loop (`:141`) | `connect` retry loop (`client.rb:117`) | ✅ | **D5 FIXED 2026-06-12**: sync failures retried with py backoff curve, last error re-raised; async-failing transports still go through the background reconnect loop |
| `close()` (`:231`) | `disconnect`/`close` (`client.rb:125`) | ✅ | |
| `is_connected` (`:96`) | `connected?` (`client.rb:137`) | ⚠️ | rb reflects real transport state (better) |
| `channel(topic, params)` dict-keyed (`:275`) | `channel` list-backed (`client.rb:150`) | ⚠️ | **D9: dup topic — py orphans, rb double-delivers** |
| `get_channels` (`:291`) | `client.rb:157` | ✅ | |
| `remove_channel` (`:297`) | `client.rb:161` | ✅ | |
| `remove_all_channels` (`:310`) | `client.rb:172` | ✅ | |
| `set_auth(token)` (`:320`) | `client.rb:185` | ⚠️ | **D3: rb only sends if connected; offline frames dropped** |
| `send(message)` buffered (`:343`) | `push(message)` buffered (`client.rb:232`) | 🟰 | renamed (avoid `Object#send`); buffering parity OK |
| `_heartbeat()` (`:255`) | heartbeat thread (`client.rb:300`) | ⚠️ | **D6: send failure swallowed; first beat delayed** |
| `_reconnect()` (`:124`) | reconnect thread (`client.rb:328`) | 🔧 | background thread + `on_reconnect_failed` instead of py's raise-from-coroutine; initial-connect retry now in `connect` itself (D5 fixed) |

### 6.2 Channel

| python | ruby | status | note |
|---|---|---|---|
| `subscribe(callback)` (`channel.py:170`) | `subscribe(&block)` (`channel.rb:80`) | 🟰 | typed `AlreadyJoinedError` vs bare `Exception` |
| `unsubscribe()` (`:278`) | `unsubscribe` (`channel.rb:115`) | ⚠️ 🐞 | **D4: rb never removes channel from client registry → leak + dispatch to dead channels** |
| `push(event, payload, timeout)` (`:298`) | `push_event(...)` (`channel.rb:228`) | ⚠️ | gate differs: py connected&&joined_once, rb requires JOINED |
| `on_postgres_changes(...)` (`:372`) | `on_postgres_changes(...)` (`channel.rb:136`) | ⚠️ | **D7: rb fires on any match before binding id arrives** |
| `on_broadcast(event, callback)` (`:357`) | `on_broadcast(event, &block)` (`channel.rb:147`) | ✅ | |
| `on_system(callback)` (`:396`) | `on_system(&block)` (`channel.rb:152`) | ⚠️ | **D8: py routes error-status to channel error; rb never errors channel** |
| `on_presence_sync/join/leave` (`:431`) | `channel.rb:172` | ⚠️ | py `_resubscribe` is itself broken; rb works but races leave-ack |
| `presence_state()` (`:423`) | `presence_state` (`channel.rb:191`) | ✅ | rb mutex-guarded dup |
| `track/untrack` (`:409`) | `track/untrack` (`channel.rb:208`) | ⚠️ | wire differs: py omits `"type"` key, rb sends `"type":"presence"` (rb matches js) |
| `send_broadcast(event, data)` (`:484`) | `send_broadcast(event, payload)` (`channel.rb:199`) | ⚠️ | rb no ref tracking; pre-subscribe buffers vs py raises |
| join-reply binding match (`:221`) | `on_join_ok` (`channel.rb:414`) | ⚠️ | py wipes callbacks if no postgres_changes in reply; rb keeps (rb saner) |

### 6.3 Realtime — critical discrepancies (ordered by severity)

**Status: D1, D2, D3, D4, D6, D8 FIXED 2026-06-12.** Regression coverage:
`spec/supabase/realtime/us008_join_access_token_spec.rb` (rewritten for D1) +
`spec/supabase/realtime/us018_realtime_cluster_parity_spec.rb` (D2/D3/D4/D8). Full
realtime+async tree: 249 examples, 0 failures (+6 in connect_retry_spec since the D5 fix). D9 remains open; D7 resolved as intentional.

- **D1 (BLOCKER) 🐞 — access_token in wrong place. ✅ FIXED.** `channel.py:215-216` puts
  `access_token` at join-payload **root**; `channel.rb:312` put it **inside `config`** →
  private channels / RLS authorized with URL apikey only, user JWT dropped. **Fix:**
  `inject_postgres_changes_bindings` writes `@join_push.payload["access_token"]` only when a
  token exists, deletes the key otherwise (py omits when falsy; rb previously emitted `null`).
  Two specs that had locked in the nested placement (us008, us015) were corrected.
- **D2 🐞 — no rejoin on phx_error. ✅ FIXED.** New `trigger_channel_error` sets ERRORED +
  `@rejoin_timer.schedule_timeout`, with a `leaving?/closed?` guard matching py's
  `if self.is_leaving or self.is_closed: return` (`channel.py:140-146`).
- **D3 🐞 — set_auth offline drops frames. ✅ FIXED.** `Client#set_auth` routes through new
  `Channel#push_access_token` (gated on `@joined_once && joined?`, matching py
  `if channel._joined_once and channel.is_joined`), which buffers in `@send_buffer` when
  offline and replays on reconnect instead of sending only when `connected?`.
- **D4 🐞 — unsubscribe leaks channel. ✅ FIXED.** Channel teardown (`handle_channel_close`,
  from leave-ack and server phx_close) calls `Client#_remove_channel(self)`, mirroring py
  `socket._remove_channel` (`channel.py:288-296`). CLOSED channels no longer receive dispatch.
- **D5 ⚠️ — no initial-connect retry. ✅ FIXED (2026-06-12).** `client.py:141-193` ↔
  `Client#connect` (`realtime/client.rb`). `connect` now retries synchronous transport
  failures with py's backoff curve (`initial_backoff * 2^(n-1)`, capped at 60s) for up to
  `max_retries` total attempts, then re-raises the last error; `auto_reconnect: false`
  raises on the first failure (py parity). Also fixes a latent bug where a synchronous
  connect raise left `@connecting` stuck at true, turning every later `connect` into a
  silent no-op. Scope note: transports that fail *asynchronously* (websocket-client-simple
  may open in the background) are still recovered by the background reconnect loop →
  `on_reconnect_failed`, same contract, different signal path. Spec:
  `spec/supabase/realtime/connect_retry_spec.rb` (6 examples incl. backoff curve,
  concurrent-disconnect abort, stuck-guard regression).
- **D6 🐞 — heartbeat error swallowed. ✅ FIXED.** Heartbeat rescue now calls
  `handle_socket_error` (stop heartbeat + `schedule_reconnect`, gated by intentional-close /
  auto_reconnect); `attach_socket` now wires `socket.on_error` to the same path (previously
  unwired), so an abrupt drop reported only via on_error still reconnects.
- **D7 ⚖️ — postgres dispatch demux strategy. RESOLVED as intentional divergence
  (2026-06-12).** py (`types.py:140-146`) AND realtime-js demux *solely* by server binding id
  (`id && ids.include?(id)`); rb filters client-side on event/schema/table and uses the id as
  an extra demux when present (`channel.rb` dispatch_postgres_changes). Decision: keep rb's
  client-side filtering — it's more robust (routes correctly even when the server omits ids)
  and the normal flow (ids recorded on join-ack) already demuxes correctly. Known narrow
  limitation, documented in code: two bindings on the same (schema, table, event) differing
  only by `:filter`, while neither has a server id yet, both fire (rb doesn't evaluate the
  PostgREST `:filter` client-side).
- **D8 ⚠️ — system error-status not escalated. ✅ FIXED.** SYSTEM dispatch routes
  `status == "error"` payloads to `trigger_channel_error`; only non-error frames reach
  `on_system` callbacks (`channel.py:520-525`).
- **D9 ⚠️ — duplicate-topic registry. OPEN** (dict overwrite vs list fan-out).

**Verified equal:** presence transform algorithm (RAW→presence_ref), push receive
(ok/error/timeout), timer backoff curve `2^(tries+1)`, rejoin backoff 4/8/16/32/64s,
transformers (http_endpoint_url, is_ws_url). Note: this realtime version has **no**
`convert_change_data` column type-casting — records delivered raw both sides (parity).

### 6.4 Realtime — rb-only surface (UX impact)

- `callback_safety.rb` — wraps user callbacks; py lets exceptions kill the listener silently.
  Improvement, but exceptions now only `warn`.
- Two transports (`websocket_client_simple` threads / `async_websocket` fibers). py is
  hardwired to `websockets`. **Concurrency contract differs:** default rb transport runs all
  callbacks on the ws background thread — py users never face cross-thread callbacks. Must be
  documented + guaranteed thread-safe for official status.
- `on_reconnect_failed`, `Channel#on_close`/`on_error`, public `send_heartbeat` — rb-only.

---

## 7. Uncertain — needs runtime confirmation

1. Does the rb top-level client feed `apikey` into realtime socket params? py hard-appends
   `?apikey=` (`client.py:78-79`); rb relies on `params:` (looks wired at `client.rb:145-151`,
   not wire-verified).
2. `jwt` gem version pin — get_claims passes `verify_expiration: false, verify_not_before: false`
   to `JWT.decode` (C-Auth-2 py-1:1 fix); option names assume modern ruby-jwt (2.x+).
3. `websocket-client-simple` reliably fires `:close` on abrupt TCP loss? Determines if D6 is real.
4. Byte-level query encoding parity: httpx `QueryParams` vs Faraday `FlatParamsEncoder` for
   `+`, space, `:` in filter values; yarl vs RFC3986 path encoding in storage.
5. `is_` boolean: py `is.True` vs rb `is.true` — does PostgREST accept both?
6. Vectors `list_indexes` snake_case body keys — does the server accept them (py bug ported)?
7. Functions Content-Type sniffing intentionally disabled in rb (spec us027) — confirm deliberate.
8. `Types::Response` / `return_response:` in functions — legacy shim, still used by anything?

---

## 8. Test coverage gaps (py-covered, rb-not)

Priority order:

1. **Realtime broadcast replay** — `test_connection.py` (3 tests: `broadcast.replay` config,
   `meta.replayed`, error on non-private). Zero rb hits for "replay" — feature may be unported.
2. **Presence resubscribe-on-late-callback** — `test_presence.py::
   test_resubscribe_on_presence_callback_addition`. rb tests only pre-subscribe.
3. **PostgREST live integration** — py `test_filter_request_builder_integration.py` (715 lines,
   real PostgREST). rb has live integration only for realtime.
4. **`Postgrest::Client#auth`** — method exists (`client.rb:60`), zero specs; basic-auth branch
   fully untested.
5. **Auth live-server tests** — entire py gotrue suite hits real GoTrue; rb is mock-only.
6. **Realtime repeated `connect()` idempotency** — `test_multiple_connect_attempts`, no rb test.

**rb-only test areas to verify as "invented behavior":** storage analytics/vectors specs (no
py tests), postgrest retry specs, realtime transport-layer specs, `AuthPKCEError`.

---

## 9. Roadmap to "official-grade" (Supabase-forkable)

Tracked separately, but summary of levels:

- **L0 — blockers:** D1 (realtime access_token), D2–D6, C-TL-1 (auth bearer refresh).
- **L1 — reconcile py-1:1 divergences:** every 🔧/🐞 row above — reproduce py or add
  `# DIVERGES FROM PY (intentional)` with rationale. Decide bug-for-bug vs documented fix.
- **L2 — operational maturity:** Dockerized integration tests (GoTrue/PostgREST/Storage/
  Realtime), CI matrix (Ruby 3.0–3.4), RuboCop, coverage gate, SemVer + CHANGELOG, YARD docs,
  documented + guaranteed-thread-safe concurrency model for realtime.
