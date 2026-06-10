# frozen_string_literal: true

require "spec_helper"
require "faraday"
require "json"

# US-024: Auth `sign_out` suppresses `AuthApiError` (F-C10 — part 2)
# Pins the contract that `sign_out` never re-raises an `AuthApiError` from the
# session-recovery / admin.sign_out paths — a stale local session that GoTrue
# rejects with 401 must still result in a clean local logout.
RSpec.describe "US-024: sign_out suppresses AuthApiError from get_session" do
  let(:base_url) { "http://localhost:9999" }
  let(:default_headers) { { "apikey" => "test-key" } }

  let(:mock_storage) do
    store = {}
    storage = Object.new
    storage.define_singleton_method(:get_item) { |key| store[key] }
    storage.define_singleton_method(:set_item) { |key, value| store[key] = value }
    storage.define_singleton_method(:remove_item) { |key| store.delete(key) }
    storage.define_singleton_method(:store) { store }
    storage
  end

  let(:mock_session) do
    {
      "access_token" => "stale-access-token",
      "refresh_token" => "stale-refresh-token",
      "token_type" => "bearer",
      "expires_in" => 3600,
      "expires_at" => Time.now.to_i + 3600,
      "user" => {
        "id" => "user-123",
        "aud" => "authenticated",
        "role" => "authenticated",
        "email" => "test@example.com",
        "phone" => "",
        "created_at" => "2024-01-01T00:00:00Z",
        "updated_at" => "2024-01-01T00:00:00Z",
        "app_metadata" => {},
        "user_metadata" => {}
      }
    }
  end

  def build_client
    stubs = Faraday::Adapter::Test::Stubs.new
    conn = Faraday.new(url: base_url) do |f|
      f.response :raise_error
      f.adapter :test, stubs
    end
    client = Supabase::Auth::Client.new(
      url: base_url,
      headers: default_headers,
      auto_refresh_token: false,
      persist_session: true,
      storage: mock_storage,
      http_client: conn
    )
    [client, stubs]
  end

  it "completes without raising and clears local session when get_session raises AuthApiError(401)" do
    client, _stubs = build_client
    mock_storage.set_item("supabase.auth.token", JSON.generate(mock_session))

    allow(client).to receive(:get_session)
      .and_raise(Supabase::Auth::Errors::AuthApiError.new("invalid JWT", status: 401))

    expect { client.sign_out }.not_to raise_error
    expect(mock_storage.store).to be_empty
  end

  it "fires SIGNED_OUT subscribers even when get_session raised AuthApiError(401)" do
    client, _stubs = build_client
    mock_storage.set_item("supabase.auth.token", JSON.generate(mock_session))

    allow(client).to receive(:get_session)
      .and_raise(Supabase::Auth::Errors::AuthApiError.new("invalid JWT", status: 401))

    events = []
    client.on_auth_state_change { |event, _session| events << event }

    expect { client.sign_out }.not_to raise_error
    expect(events).to include("SIGNED_OUT")
  end

  it "still suppresses AuthApiError when admin.sign_out is the one raising it" do
    client, _stubs = build_client
    mock_storage.set_item("supabase.auth.token", JSON.generate(mock_session))

    allow(client.admin).to receive(:sign_out)
      .and_raise(Supabase::Auth::Errors::AuthApiError.new("invalid JWT", status: 401))

    expect { client.sign_out }.not_to raise_error
    expect(mock_storage.store).to be_empty
  end
end
