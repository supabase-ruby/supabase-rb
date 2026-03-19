# supabase-auth

[![Gem Version](https://img.shields.io/gem/v/supabase-auth)](https://rubygems.org/gems/supabase-auth)
[![CI](https://github.com/supabase/supabase-rb/actions/workflows/ci.yml/badge.svg)](https://github.com/supabase/supabase-rb/actions/workflows/ci.yml)
[![Ruby](https://img.shields.io/badge/ruby-%3E%3D%203.0-red)](https://www.ruby-lang.org)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

Ruby client for [Supabase Auth](https://supabase.com/docs/guides/auth) (GoTrue API).

## Features

- Email/password, phone, and anonymous sign-in
- OAuth and SSO provider support
- Magic link and OTP verification
- PKCE authentication flow
- MFA (TOTP and phone)
- JWT verification with JWKS support
- Session management with auto-refresh
- Admin API for user management
- Auth state change subscriptions

## Installation

Add to your Gemfile:

```ruby
gem "supabase-auth"
```

Then run:

```bash
bundle install
```

## Quick Start

```ruby
require "supabase/auth"

client = Supabase::Auth::Client.new(
  url: "https://your-project.supabase.co/auth/v1",
  headers: { "apiKey" => "your-anon-key" }
)

# Sign up
response = client.sign_up(email: "user@example.com", password: "secure-password")

# Sign in
response = client.sign_in_with_password(email: "user@example.com", password: "secure-password")

# Get session and user
session = client.get_session
user = client.get_user
```

## Usage

### Authentication

```ruby
# Email/password
client.sign_in_with_password(email: "user@example.com", password: "password")

# Magic link (OTP)
client.sign_in_with_otp(email: "user@example.com")

# Phone OTP
client.sign_in_with_otp(phone: "+1234567890")

# OAuth
response = client.sign_in_with_oauth(provider: "google")

# SSO
response = client.sign_in_with_sso(domain: "company.com")

# ID token (e.g. from Google Sign-In)
response = client.sign_in_with_id_token(provider: "google", token: "id-token")

# Anonymous
response = client.sign_in_anonymously

# Sign out
client.sign_out
```

### Session Management

```ruby
# Set session from existing tokens
client.set_session("access_token", "refresh_token")

# Refresh session
client.refresh_session

# Exchange code for session (PKCE)
client.exchange_code_for_session(auth_code: "code")

# Listen for auth state changes
subscription = client.on_auth_state_change do |event, session|
  puts "Auth event: #{event}"
end

# Unsubscribe
subscription.unsubscribe.call
```

Auth events: `SIGNED_IN`, `SIGNED_OUT`, `TOKEN_REFRESHED`, `USER_UPDATED`, `MFA_CHALLENGE_VERIFIED`, `PASSWORD_RECOVERY`

### User Management

```ruby
# Get current user
user = client.get_user

# Update user
client.update_user(data: { name: "Jane Doe" })

# Reset password
client.reset_password_for_email("user@example.com")

# Verify OTP
client.verify_otp(type: "email", email: "user@example.com", token: "123456")

# Identity linking
client.link_identity(provider: "github")
client.unlink_identity(identity)
```

### MFA (Multi-Factor Authentication)

```ruby
# Enroll a TOTP factor
enrolled = client.mfa.enroll(factor_type: "totp")

# Challenge
challenge = client.mfa.challenge(factor_id: enrolled["id"])

# Verify
client.mfa.verify(factor_id: enrolled["id"], challenge_id: challenge.id, code: "123456")

# List factors
factors = client.mfa.list_factors

# Get assurance level
aal = client.mfa.get_authenticator_assurance_level

# Unenroll
client.mfa.unenroll(factor_id: enrolled["id"])
```

### JWT Verification

```ruby
# Verify and extract JWT claims (supports HS256, RS256, ES256, PS256+)
claims = client.get_claims(jwt: "eyJhbG...")
claims.claims  # decoded payload
claims.headers # JWT headers
```

### Admin API

Requires a service role key.

```ruby
admin = Supabase::Auth::AdminApi.new(
  url: "https://your-project.supabase.co/auth/v1",
  headers: { "Authorization" => "Bearer #{service_role_key}", "apiKey" => service_role_key }
)

# CRUD operations
user = admin.create_user(email: "new@example.com", password: "password")
users = admin.list_users(page: 1, per_page: 50)
user = admin.get_user_by_id("uuid")
admin.update_user_by_id("uuid", email: "updated@example.com")
admin.delete_user("uuid")

# Invite user
admin.invite_user_by_email("user@example.com")

# Generate links
admin.generate_link(type: "signup", email: "user@example.com", password: "password")

# Sign out a user
admin.sign_out("access_token")
```

### Configuration Options

```ruby
client = Supabase::Auth::Client.new(
  url: "https://your-project.supabase.co/auth/v1",
  headers: { "apiKey" => "your-anon-key" },
  auto_refresh_token: true,    # Auto-refresh expiring tokens (default: true)
  persist_session: true,        # Persist session to storage (default: true)
  detect_session_in_url: true,  # Detect OAuth callback in URL (default: true)
  flow_type: "implicit",        # "implicit" or "pkce" (default: "implicit")
  storage: custom_storage        # Custom storage backend (default: in-memory)
)
```

## Development

### Prerequisites

- Ruby >= 3.0
- Docker & Docker Compose (for integration tests)

### Setup

```bash
bundle install
```

### Running Tests

Start the GoTrue infrastructure:

```bash
docker compose -f infra/docker-compose.yml up -d
```

Run the test suite:

```bash
bundle exec rspec
```

Coverage reports are generated automatically via SimpleCov. After running tests, open `coverage/index.html`.

## License

MIT
