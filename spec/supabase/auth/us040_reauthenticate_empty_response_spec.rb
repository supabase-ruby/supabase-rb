# frozen_string_literal: true

require "spec_helper"

# US-040: `reauthenticate` must return an empty `AuthResponse(user: nil, session: nil)`,
# paritetно с supabase-py (`return AuthResponse(user=None, session=None)`).
# AC: "Spec: `reauthenticate` → `result.user == nil && result.session == nil`."
RSpec.describe "Supabase::Auth::Client#reauthenticate empty response (US-040)" do
  let(:client) do
    Supabase::Auth::Client.new(
      url: "http://localhost:9998",
      headers: { "X-Test" => "1" },
      persist_session: false
    )
  end

  let(:mock_session) do
    Supabase::Auth::Types::Session.new(
      access_token: "at",
      refresh_token: "rt",
      token_type: "bearer",
      expires_in: 3600,
      expires_at: Time.now.to_i + 3600,
      user: Supabase::Auth::Types::User.new(id: "u1")
    )
  end

  it "returns AuthResponse with user: nil and session: nil even when server returns a populated body" do
    allow(client).to receive(:get_session).and_return(mock_session)
    allow(client).to receive(:_request).and_return(
      "access_token" => "new-at",
      "refresh_token" => "new-rt",
      "expires_in" => 3600,
      "token_type" => "bearer",
      "user" => { "id" => "u1" }
    )

    result = client.reauthenticate

    expect(result).to be_a(Supabase::Auth::Types::AuthResponse)
    expect(result.user).to be_nil
    expect(result.session).to be_nil
  end

  it "still issues the GET /reauthenticate request with the session JWT (regression guard)" do
    allow(client).to receive(:get_session).and_return(mock_session)
    allow(client).to receive(:_request).and_return({})

    client.reauthenticate

    expect(client).to have_received(:_request).with("GET", "reauthenticate", hash_including(jwt: "at"))
  end
end
