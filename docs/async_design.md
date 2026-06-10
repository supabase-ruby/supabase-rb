# Async variant design — `Supabase::Auth::Async`

**Status:** Recommended, validated by working spike
**Companion task:** Taskmaster task #7 (this doc) → unblocks task #8 (full async implementation)
**Spike code:** `lib/supabase/auth/async/{api,client}.rb`
**Spike spec:** `spec/supabase/auth/async/spike_spec.rb` (3/3 green against live GoTrue)

---

## 1. Goal

`supabase-py` ships paired `_sync/` and `_async/` packages for every sub-library, generated from one source by `scripts/run-unasync.py`. Ruby needs an equivalent — methods that mirror sync 1:1 but yield to a reactor on every I/O wait so callers can drive many requests concurrently from one thread.

## 2. Stack

| Layer | Choice | Why |
|---|---|---|
| HTTP client | **Faraday** (unchanged) | Already the sync gem's HTTP base; reusing it keeps the public surface identical and reuses middleware/error mapping |
| Async adapter | **`async-http-faraday`** (≥ 0.20) | Drop-in Faraday adapter (`f.adapter :async_http`) built on `async-http`; Fiber-aware, no code change in calling sites |
| Reactor | **`async`** gem (≥ 2.0) | Socketry's Fiber-based reactor — the default Ruby ecosystem choice for async I/O |
| Concurrency unit | **Ruby `Fiber`** | Native, cooperative, no thread pool to manage. Same mental model as Python `asyncio` |

Versions confirmed available on RubyGems:
- `async 2.39.0`
- `async-http-faraday 0.22.2`

Both are actively maintained (last release within months) and battle-tested in production (Falcon web server, Async::Container).

## 3. Architecture options considered

### Option A — Separate classes (chosen)

```
lib/supabase/auth/
  client.rb           # sync Supabase::Auth::Client (unchanged)
  api.rb              # sync Supabase::Auth::Api (unchanged)
  async/
    client.rb         # Supabase::Auth::Async::Client
    api.rb            # Supabase::Auth::Async::Api
    admin_api.rb      # Supabase::Auth::Async::AdminApi
    admin_oauth_api.rb
    mfa.rb            # Supabase::Auth::Async::MFAApi
```

**Pros**
- Mirrors `supabase-py`'s file layout 1:1 — anyone reading the Python docs can find the Ruby equivalent by name
- Sync and async clients can each be required à la carte (`require 'supabase/auth'` stays free of `async-http-faraday`)
- Each class has a single execution model — no runtime branching on a `mode:` flag
- Sync gem users pay zero cost: no extra deps, no fiber scheduler boot
- Easy to test, easy to read stacktraces

**Cons**
- Two parallel codebases — same risk as Python. Mitigated by section 5 (codegen vs hand-maintained twin).

### Option B — Single client, `async: true` mode flag

```ruby
client = Supabase::Auth::Client.new(url:, headers:, async: true)
```

**Pros**
- One file to maintain
- Caller picks behavior at construction time

**Cons** — *why this was rejected*
- Forces the production sync gem to depend on `async-http-faraday` even when no caller uses async
- Every method becomes a branch on `@async` — half the code is dead in any given runtime
- Stacktraces leak fiber internals into sync users' bug reports
- Diverges from the Python file layout we promised to mirror — breaks the "read Python docs, use Ruby" property called out in the PRD
- Future contributors will keep "fixing" the branches independently and they'll drift

### Option C — Hybrid shared base + sync/async subclasses

A `BaseClient` with shared parsing/state, and `SyncClient`/`AsyncClient` overriding `_request`.

**Pros**
- Less duplication than A

**Cons**
- The shared base is mostly *state management* (session cache, JWKS cache, subscribers) and *parsing* — neither of which differs between sync and async
- The thing that *does* differ (the HTTP call) is so small that subclassing for it adds more ceremony than it removes
- Subclassing a 1000-line `Client` is a long-running maintenance hazard: every method becomes "is this overridden or inherited?"
- Sync users still pay the cost of loading `async-http-faraday` because the base file requires the subclass file

### Recommendation: **Option A**

Separate classes, separate file trees, separate test suites, separate gemspec story (async deps stay as dev/optional). Same decision Python made, for the same reasons.

## 4. Public API shape — Ruby idiom

The async client is called from inside an `Async do ... end` block. Method signatures and return types are **identical** to the sync client; the only difference is *where* you call them from.

```ruby
require 'supabase/auth'
require 'supabase/auth/async/client'
require 'async'

async_client = Supabase::Auth::Async::Client.new(
  url: 'https://project.supabase.co/auth/v1',
  headers: { 'apikey' => key }
)

# Single call
Async do
  response = async_client.sign_in_with_password(email:, password:)
  response.session.access_token # => "eyJ..."
end

# Concurrent calls
Async do |task|
  tasks = users.map do |u|
    task.async { async_client.sign_in_with_password(email: u.email, password: u.password) }
  end
  tasks.map(&:wait) # => [AuthResponse, AuthResponse, ...]
end
```

This is the closest Ruby analog to Python's `async def` / `await` model. The async gem's fiber scheduler handles the rest — no `Promise`, no `Future`, no callbacks.

**Trade-off:** callers must remember to wrap in `Async do`. The alternative — returning `Async::Task` objects from every method — looks like sync code from the outside but requires `.wait` everywhere and produces unfamiliar stacktraces. Mirroring Python's `await x` semantics is the more readable choice.

## 5. Codegen vs hand-maintained twin

Python uses `scripts/run-unasync.py` (the `unasync` library) which rewrites `_async/*.py` → `_sync/*.py` by stripping `async`/`await` and renaming a few classes. The transformation is tractable because the diff between sync and async Python is mechanical.

Ruby's diff is even smaller — the *only* difference between sync and async classes in the spike is **one line**:

```ruby
f.adapter Faraday.default_adapter   # sync
f.adapter :async_http               # async
```

There is no `await` to strip, no `async def` to rename, no `asyncio.gather` to replace. The HTTP call site is identical; the reactor handles the rest.

**Recommendation: hand-maintained twin.** Specifically:

1. The two `api.rb` files are nearly identical (~80 lines each, one adapter line different). Extract the shared logic into a `Supabase::Auth::BaseApi` mix-in if drift becomes a problem; for now, ~80 lines × 2 is below the maintenance threshold that justifies tooling.
2. `client.rb` is the only large file (~1000 lines). The async variant delegates to a `Supabase::Auth::Async::Api` for HTTP but otherwise *reuses the sync class's logic* via inheritance for non-HTTP methods (parsing, session storage, JWKS cache). The HTTP-touching methods are overridden to use the async API.
3. If we ever want codegen, the Ruby `parser`/`prism` ecosystem can transform one to the other with a 30-line script — easier than `unasync` because there's no async syntax to preserve.

The PRD explicitly raised "Codegen pipeline analogous to unasync, or hand-maintained twin?" — the answer for Ruby is "hand-maintained, because there's nothing to generate."

## 6. Shared-state strategy

The sync client maintains in-process state — `@current_session`, `@jwks` cache, `@state_change_emitters`, `@refresh_token_timer`. Async variants need the same state but **must not share instances across fibers without care**.

Decision: each `Async::Client` carries its own session/JWKS/subscriber state, same as `Client`. Two fibers using the same `Async::Client` will see each other's state changes (e.g. one fiber's `sign_in` updates the session for the other). This is the same contract sync `Client` already offers across threads — callers who want isolation construct a new client per fiber.

The reactor doesn't preempt — state mutations between two fiber yields are atomic. No locks needed.

## 7. Spike results

Run with the docker-compose GoTrue infra (port 9998 — autoconfirm-on).

```bash
docker compose -f infra/docker-compose.yml up -d
bundle exec rspec spec/supabase/auth/async/spike_spec.rb
```

**Result:** 3/3 examples pass.

- ✅ Single `sign_in_with_password` call inside `Async do` returns a populated `AuthResponse` with `session.access_token`
- ✅ `AuthInvalidCredentialsError` propagates correctly through fiber boundaries when password is missing
- ✅ 5 concurrent sign-in calls in one `Async do |task|` block complete in < 3× baseline single-call latency (fiber-parallel; serial execution would be ~5×)

The full sync suite (1473 examples) also passes alongside the spike — confirming the async additions don't disturb anything.

## 8. Migration plan for task #8

Implement async variants in dependency order:

1. `Async::Api` — already in spike; final version goes into `lib/supabase/auth/async/api.rb`
2. `Async::AdminApi` — mirrors `AdminApi`; carries its own `Async::Api`
3. `Async::AdminOAuthApi` — thin wrapper, mirrors `AdminOAuthApi`
4. `Async::MFAApi` — depends on `Async::Client` (for session access)
5. `Async::Client` — biggest, mirrors `Client` method-by-method

Each lands with parallel specs under `spec/supabase/auth/async/`. The spike spec stays as the canonical smoke test for the stack.

For non-HTTP helpers (`Helpers.parse_*`, `Types::*.from_hash`, `Errors::*`) — reuse the sync module verbatim. No async story needed; they're pure functions.

## 9. Gemspec / packaging

The production `supabase-auth` gemspec **does not** depend on `async` or `async-http-faraday`. They're development dependencies only, so:

- Sync-only users install `supabase-auth` and get zero async transitive deps
- Async users add `gem 'async', gem 'async-http-faraday'` to their own Gemfile and `require 'supabase/auth/async/client'`

When the monorepo splits into a meta-gem (task #16), we can offer:
- `supabase-auth` — sync only (current)
- `supabase-auth-async` — depends on `supabase-auth` + `async-http-faraday`, adds the `lib/supabase/auth/async/` tree
- `supabase` umbrella — pulls both, exposes `Supabase.create_client(async: true)`

This three-tier split keeps the dependency surface honest.

## 10. `apply_auth` under `async: true` — non-blocking realtime fan-out

`Supabase::Client#set_auth` (and the `on_auth_state_change` listener installed on
`#auth`) funnels through the private `#apply_auth(token)` on the umbrella. That
method rotates the shared `Authorization` header, nils out the memoized REST sub-
clients, and then calls `@realtime&.set_auth(token)` — which iterates every
joined channel and synchronously pushes an `ACCESS_TOKEN` frame through the
Realtime `Socket#send` for each one.

Under the sync client that's fine: the caller is on a thread, and a slow send is
a slow `send`. Under `async: true` it is **not** fine: the calling fiber is
expected to keep flowing, and a `Socket#send` that takes hundreds of
milliseconds (slow network, large fan-out) means the calling fiber sits on the
floor for the full duration even though the reactor itself happily schedules
sibling fibers (cooperative `Kernel.sleep`).

`apply_auth` therefore branches on `@async`:

```ruby
def apply_auth(token)
  @headers["Authorization"] = "Bearer #{token || @supabase_key}"
  @storage = @functions = @postgrest = nil
  if @async
    require "async" unless defined?(Async)
    Async { @realtime&.set_auth(token) }
  else
    @realtime&.set_auth(token)
  end
end
```

- `async: false` — unchanged: the realtime fan-out runs inline on the caller.
- `async: true` — the fan-out is wrapped in `Async { ... }`. When invoked from
  inside an existing reactor (the documented usage pattern in §4) this spawns a
  child task on the current scheduler and the calling fiber returns
  immediately. The outer `Async do ... end` block will still wait for the child
  task to drain before it exits, so the `ACCESS_TOKEN` frame is guaranteed to
  reach every channel — it just isn't *awaited* inline by the caller. Called
  from outside a reactor, `Async { ... }` boots a one-shot reactor and runs
  synchronously, matching the sync semantics so misconfigured callers don't
  silently lose the fan-out.

The reproducer + regression test for this behaviour is
**`spec/async/apply_auth_non_blocking_spec.rb`** (originally landed under
US-047 as a `pending` measurement, flipped green under US-048). It builds an
`async: true` umbrella, swaps in a `Realtime::Client` backed by a transport
whose `Socket#send` sleeps for `WRITE_DELAY = 0.2 s`, forces one channel to
`JOINED`, and from inside an `Async do |task| ... end` block measures
`apply_auth_duration` while a sibling ticker fiber counts ticks. After the fix
the calling fiber returns in well under `WRITE_DELAY` (the `expect` asserts
`apply_auth_duration < WRITE_DELAY`) and the slow send still completes before
the outer Async block exits.

## 11. Open questions deferred to task #8

- **Timeout semantics**: `async-http-faraday` honors Faraday's `timeout`/`open_timeout`. Need to verify behavior under cancellation (`task.stop`) and that errors map correctly.
- **Retry middleware**: sync uses Faraday's `:retry` middleware. Need to confirm it composes with the async adapter (it should — middleware sits above the adapter).
- **Long-poll patterns** (auth state subscriptions): these are local, not HTTP, so unaffected. But the timer-based `@refresh_token_timer` (currently `Thread`-based) should switch to `Async::Task#sleep` inside an async client to avoid blocking a thread.
- **Session storage**: `MemoryStorage` is thread-safe-enough; an async-aware variant isn't needed because the reactor serializes fiber-level access.
