# frozen_string_literal: true

require "spec_helper"
require "async"
require "supabase/auth/async"

# Async::AdminApi end-to-end against the live GoTrue infra. Verifies admin user
# CRUD methods inherited from sync AdminApi dispatch through the async adapter.
RSpec.describe Supabase::Auth::Async::AdminApi do
  let(:url) { TestClients::GOTRUE_URL_SIGNUP_ENABLED_AUTO_CONFIRM_ON }
  let(:admin) do
    described_class.new(
      url: url,
      headers: { "Authorization" => "Bearer #{TestClients::SERVICE_ROLE_JWT}" }
    )
  end
  let(:credentials) { mock_user_credentials }

  before(:each) do
    WebMock.allow_net_connect! if defined?(WebMock)
  rescue Errno::ECONNREFUSED, Supabase::Auth::Errors::AuthRetryableError
    skip "GoTrue infra not running (docker compose -f infra/docker-compose.yml up -d)"
  end

  it "inherits from sync AdminApi" do
    expect(described_class.ancestors).to include(Supabase::Auth::AdminApi)
  end

  it "exposes Async::AdminOAuthApi via .oauth" do
    expect(admin.oauth).to be_a(Supabase::Auth::Async::AdminOAuthApi)
  end

  it "follows 3xx redirects like the sync AdminApi (httpx follow_redirects=True)" do
    handler_names = admin.send(:connection).builder.handlers.map { |h| h.klass.name }
    expect(handler_names).to include("FaradayMiddleware::FollowRedirects").or(
      include("Faraday::FollowRedirects::Middleware")
    )
  end

  describe "user CRUD round trip" do
    it "creates, reads, updates, then deletes a user" do
      created_id = nil
      Async do
        created = admin.create_user(
          email: credentials[:email],
          password: credentials[:password]
        )
        expect(created).to be_a(Supabase::Auth::Types::UserResponse)
        created_id = created.user.id

        fetched = admin.get_user_by_id(created_id)
        expect(fetched.user.id).to eq(created_id)
        expect(fetched.user.email).to eq(credentials[:email])

        updated = admin.update_user_by_id(
          created_id,
          user_metadata: { display_name: "Async Test" }
        )
        expect(updated.user.user_metadata["display_name"]).to eq("Async Test")

        admin.delete_user(created_id)
      end.wait
    end
  end

  describe "list_users" do
    it "returns an array of User objects" do
      users = nil
      Async do
        admin.create_user(email: credentials[:email], password: credentials[:password])
        users = admin.list_users(page: 1, per_page: 50)
      end.wait

      expect(users).to be_an(Array)
      expect(users.first).to be_a(Supabase::Auth::Types::User)
    end
  end
end
