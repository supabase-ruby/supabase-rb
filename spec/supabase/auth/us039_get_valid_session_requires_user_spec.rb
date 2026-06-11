# frozen_string_literal: true

require "spec_helper"
require "json"

# US-005 supersedes US-039. The earlier "audit" PRD required `_get_valid_session`
# to reject session payloads without a `user`. The new PRD ("parity with
# supabase-py") relaxes that check to match py's `_get_valid_session`, which
# only enforces `expires_at` explicitly (see `gotrue_client.py:_get_valid_session`).
# These cases now lock in the post-US-005 contract — kept under the old name
# as a regression guard so reverts to the strict check fail loudly here.
RSpec.describe "Supabase::Auth::Client#_get_valid_session user requirement (US-005 supersedes US-039)" do
  let(:client) do
    Supabase::Auth::Client.new(
      url: "http://localhost:9998",
      headers: { "X-Test" => "1" },
      persist_session: false
    )
  end

  let(:future_ts) { Time.now.to_i + 3600 }

  let(:valid_session_hash) do
    {
      "access_token" => "at",
      "refresh_token" => "rt",
      "expires_at" => future_ts,
      "expires_in" => 3600,
      "token_type" => "bearer",
      "user" => { "id" => "u1" }
    }
  end

  it "accepts session when user key is absent (parity with py)" do
    raw = JSON.generate(valid_session_hash.reject { |k, _| k == "user" })
    session = client.send(:_get_valid_session, raw)
    expect(session).to be_a(Supabase::Auth::Types::Session)
    expect(session.user).to be_nil
  end

  it "accepts session when user value is null (parity with py)" do
    raw = JSON.generate(valid_session_hash.merge("user" => nil))
    session = client.send(:_get_valid_session, raw)
    expect(session).to be_a(Supabase::Auth::Types::Session)
    expect(session.user).to be_nil
  end

  it "returns a Session when user is present (regression guard)" do
    raw = JSON.generate(valid_session_hash)
    session = client.send(:_get_valid_session, raw)
    expect(session).to be_a(Supabase::Auth::Types::Session)
    expect(session.user).to be_a(Supabase::Auth::Types::User)
  end

  it "accepts a symbol-keyed hash without user (parity with py)" do
    hash = {
      access_token: "at",
      refresh_token: "rt",
      expires_at: future_ts,
      expires_in: 3600,
      token_type: "bearer"
    }
    session = client.send(:_get_valid_session, hash)
    expect(session).to be_a(Supabase::Auth::Types::Session)
    expect(session.user).to be_nil
  end

  it "returns a Session for a symbol-keyed hash with user" do
    hash = {
      access_token: "at",
      refresh_token: "rt",
      expires_at: future_ts,
      expires_in: 3600,
      token_type: "bearer",
      user: { id: "u1" }
    }
    session = client.send(:_get_valid_session, hash)
    expect(session).to be_a(Supabase::Auth::Types::Session)
  end
end
