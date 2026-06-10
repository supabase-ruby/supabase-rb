# frozen_string_literal: true

require "spec_helper"
require "json"

# US-039: `_get_valid_session` must reject session payloads without a `user`.
# AC: "Spec: session payload без user → `_get_valid_session` возвращает nil."
RSpec.describe "Supabase::Auth::Client#_get_valid_session user requirement (US-039)" do
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

  it "returns nil when user key is absent" do
    raw = JSON.generate(valid_session_hash.reject { |k, _| k == "user" })
    expect(client.send(:_get_valid_session, raw)).to be_nil
  end

  it "returns nil when user value is null" do
    raw = JSON.generate(valid_session_hash.merge("user" => nil))
    expect(client.send(:_get_valid_session, raw)).to be_nil
  end

  it "returns a Session when user is present (regression guard)" do
    raw = JSON.generate(valid_session_hash)
    session = client.send(:_get_valid_session, raw)
    expect(session).to be_a(Supabase::Auth::Types::Session)
    expect(session.user).to be_a(Supabase::Auth::Types::User)
  end

  it "returns nil for a symbol-keyed hash without user (defensive)" do
    hash = {
      access_token: "at",
      refresh_token: "rt",
      expires_at: future_ts,
      expires_in: 3600,
      token_type: "bearer"
    }
    expect(client.send(:_get_valid_session, hash)).to be_nil
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
