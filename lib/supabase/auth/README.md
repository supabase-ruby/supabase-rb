# `supabase-auth`

Ruby client for [Supabase Auth](https://supabase.com/docs/guides/auth)
(GoTrue). Sign-in flows, session management, MFA, JWT verification, OAuth,
and admin user management. Mirrors the public surface of
[`supabase_auth`](https://github.com/supabase/supabase-py/tree/main/src/auth)
in Python.

- Source: [github.com/supabase-rb/client](https://github.com/supabase-rb/client)
- RubyGems: [rubygems.org/gems/supabase-auth](https://rubygems.org/gems/supabase-auth)

## Installation

```ruby
gem "supabase-auth"
```

Then `bundle install`. (Requires Ruby >= 3.0.)

## Usage

```ruby
require "supabase/auth"

client = Supabase::Auth::Client.new(
  url: "https://your-project.supabase.co/auth/v1",
  headers: { "apiKey" => "your-anon-key" }
)

response = client.sign_in_with_password(email: "user@example.com", password: "pw")
session  = client.get_session
user     = client.get_user
```

### Sign-in methods

```ruby
client.sign_in_with_password(email:, password:)
client.sign_in_with_otp(email:)             # magic link
client.sign_in_with_otp(phone:)             # SMS OTP
client.sign_in_with_oauth(provider: "google")
client.sign_in_with_sso(domain: "company.com")
client.sign_in_with_id_token(provider:, token:)
client.sign_in_anonymously
client.sign_out
```

### Session lifecycle

```ruby
client.set_session("access_token", "refresh_token")
client.refresh_session
client.exchange_code_for_session(auth_code: "code")   # PKCE

subscription = client.on_auth_state_change { |event, session| ... }
subscription.unsubscribe.call
```

Events: `SIGNED_IN`, `SIGNED_OUT`, `TOKEN_REFRESHED`, `USER_UPDATED`,
`MFA_CHALLENGE_VERIFIED`, `PASSWORD_RECOVERY`.

### MFA

```ruby
enrolled  = client.mfa.enroll(factor_type: "totp")
challenge = client.mfa.challenge(factor_id: enrolled["id"])
client.mfa.verify(factor_id: enrolled["id"], challenge_id: challenge.id, code: "123456")

client.mfa.challenge_and_verify(factor_id: enrolled["id"], code: "123456")
client.mfa.get_authenticator_assurance_level
client.mfa.list_factors
client.mfa.unenroll(factor_id: enrolled["id"])
```

### JWT verification

```ruby
claims = client.get_claims(jwt: "eyJhbG...")
claims.claims   # decoded payload
claims.headers  # JWT headers
```

Supports HS256, RS256, ES256, PS256+ (and their 384/512 variants).

### Admin API

```ruby
admin = Supabase::Auth::AdminApi.new(
  url: "https://your-project.supabase.co/auth/v1",
  headers: { "Authorization" => "Bearer #{service_role}", "apiKey" => service_role }
)

admin.create_user(email:, password:)
admin.list_users(page: 1, per_page: 50)
admin.invite_user_by_email("user@example.com")
admin.generate_link(type: "signup", email:, password:)

# OAuth 2.1 client administration (when the OAuth server feature is enabled)
admin.oauth.create_client(client_name:, redirect_uris:)
admin.oauth.list_clients(page: 1, per_page: 20)
admin.oauth.regenerate_client_secret("client-uuid")
```

### Async variant

```ruby
require "supabase/auth/async"

async_client = Supabase::Auth::Async::Client.new(
  url: "https://your-project.supabase.co/auth/v1",
  headers: { "apiKey" => "your-anon-key" }
)

Async do
  user = async_client.get_user
end
```

Built on [`async-http-faraday`](https://github.com/socketry/async-http-faraday).
Loaded only when you `require "supabase/auth/async"` so sync-only users pay
zero cost.

### Constructor options

```ruby
Supabase::Auth::Client.new(
  url:                   "...",
  headers:               { "apiKey" => "..." },
  auto_refresh_token:    true,
  persist_session:       true,
  detect_session_in_url: true,
  flow_type:             "implicit",   # or "pkce"
  storage:               custom_storage
)
```

## Ruby-specific additions

The Ruby port carries two intentional enhancements over `supabase_auth` (py),
documented here so they don't get "fixed" to match Python.

### `AuthPKCEError`

`Supabase::Auth::Errors::AuthPKCEError` is a dedicated exception for
PKCE-flow failures (missing or invalid `code_verifier` during
`exchange_code_for_session`). Python raises a generic `AuthError`; the
dedicated class gives callers a precise `rescue` target.

### Explicit JWT algorithm → digest mapping

`Supabase::Auth::Client::ALG_TO_DIGEST` is a frozen lookup table:

```ruby
ALG_TO_DIGEST = {
  "RS256" => "SHA256", "RS384" => "SHA384", "RS512" => "SHA512",
  "ES256" => "SHA256", "ES384" => "SHA384", "ES512" => "SHA512",
  "PS256" => "SHA256", "PS384" => "SHA384", "PS512" => "SHA512"
}.freeze
```

Python resolves algorithms dynamically via `PyJWT.get_algorithm_by_name`.
The Ruby table makes the supported set readable in one place and fails fast
(`AuthInvalidJwtError`) on unsupported `alg` values.

## Development

Integration tests need the GoTrue stack on ports 9996–9999:

```bash
docker compose -f infra/docker-compose.yml up -d
bundle exec rspec spec/supabase/auth/ spec/client_spec.rb spec/admin_api_spec.rb
```
