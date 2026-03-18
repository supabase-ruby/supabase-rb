# supabase-auth-rb

[![CI](https://github.com/supabase/supabase-rb/actions/workflows/ci.yml/badge.svg)](https://github.com/supabase/supabase-rb/actions/workflows/ci.yml)
[![Ruby](https://img.shields.io/badge/ruby-%3E%3D%203.0-red)](https://www.ruby-lang.org)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

Ruby client for [Supabase Auth](https://supabase.com/docs/guides/auth) (GoTrue API). Ported from [supabase/auth-py](https://github.com/supabase/auth-py).

## Installation

Add to your Gemfile:

```ruby
gem "supabase-auth"
```

Then run:

```bash
bundle install
```

## Usage

```ruby
require "supabase/auth"

client = Supabase::Auth::Client.new(
  url: "https://your-project.supabase.co/auth/v1",
  headers: { "apiKey" => "your-anon-key" }
)

# Sign up
response = client.sign_up(email: "user@example.com", password: "secure-password")

# Sign in with password
response = client.sign_in_with_password(email: "user@example.com", password: "secure-password")

# Sign in with magic link (OTP)
client.sign_in_with_otp(email: "user@example.com")

# Sign in with phone OTP
client.sign_in_with_otp(phone: "+1234567890")

# Sign in with OAuth
response = client.sign_in_with_oauth(provider: "google")

# Sign in anonymously
response = client.sign_in_anonymously

# Get current session
session = client.get_session

# Get current user
user = client.get_user

# Update user profile
client.update_user(data: { name: "Jane Doe" })

# Sign out
client.sign_out
```

### Session Management

```ruby
# Set session from existing tokens
client.set_session("access_token", "refresh_token")

# Refresh session
client.refresh_session

# Listen for auth state changes
subscription = client.on_auth_state_change do |event, session|
  puts "Auth event: #{event}"
end

# Unsubscribe
subscription.unsubscribe.call
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

# Unenroll
client.mfa.unenroll(factor_id: enrolled["id"])
```

### Admin API

```ruby
admin = Supabase::Auth::AdminApi.new(
  url: "https://your-project.supabase.co/auth/v1",
  headers: { "Authorization" => "Bearer #{service_role_key}", "apiKey" => service_role_key }
)

# Create user
user = admin.create_user(email: "new@example.com", password: "password")

# List users
users = admin.list_users

# Get user by ID
user = admin.get_user_by_id("uuid")

# Update user
admin.update_user_by_id("uuid", email: "updated@example.com")

# Delete user
admin.delete_user("uuid")
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

### Code Coverage

Coverage reports are generated automatically via SimpleCov. After running tests, open `coverage/index.html`.

## License

MIT
