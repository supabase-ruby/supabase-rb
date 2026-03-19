# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"
require "json"
require "securerandom"

# US-004: Audit Admin API Methods
# Verifies that Ruby Admin API methods match Python behavior:
#   - create_user sends POST to /admin/users with AdminUserAttributes
#   - list_users supports page/per_page pagination params
#   - get_user_by_id validates UUID format
#   - update_user_by_id sends PUT to /admin/users/{uid}
#   - delete_user supports should_soft_delete parameter
#   - invite_user_by_email sends data and redirect_to options
#   - generate_link constructs correct body for all link types
#   - sign_out sends scope as query param (FINDING: Ruby uses jwt param in _request, matching Python)
#   - Admin MFA _list_factors and _delete_factor work correctly
RSpec.describe "US-004: Admin API Methods Audit" do
  let(:base_url) { "http://localhost:9998" }
  let(:admin_api) do
    Supabase::Auth::AdminApi.new(
      url: base_url,
      headers: { "Authorization" => "Bearer service-role-jwt" }
    )
  end

  let(:test_uuid) { "550e8400-e29b-41d4-a716-446655440000" }
  let(:test_factor_id) { "660e8400-e29b-41d4-a716-446655440000" }

  let(:mock_user_hash) do
    {
      "id" => test_uuid,
      "app_metadata" => { "provider" => "email" },
      "user_metadata" => { "name" => "Test User" },
      "aud" => "authenticated",
      "email" => "test@example.com",
      "phone" => "",
      "created_at" => "2023-01-01T00:00:00Z",
      "confirmed_at" => "2023-01-01T00:00:00Z",
      "last_sign_in_at" => "2023-01-01T00:00:00Z",
      "role" => "authenticated",
      "updated_at" => "2023-01-01T00:00:00Z",
      "identities" => [],
      "factors" => []
    }
  end

  before do
    WebMock.disable_net_connect!
  end

  after do
    WebMock.allow_net_connect!
  end

  # ── AC-1: create_user sends POST to /admin/users with AdminUserAttributes ──

  describe "AC-1: create_user sends POST to /admin/users" do
    it "sends POST with email and password attributes" do
      stub = stub_request(:post, "#{base_url}/admin/users")
        .with(
          body: { email: "new@example.com", password: "secret123" }.to_json,
          headers: { "Content-Type" => "application/json;charset=UTF-8" }
        )
        .to_return(
          status: 200,
          body: { "user" => mock_user_hash }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = admin_api.create_user(email: "new@example.com", password: "secret123")
      expect(stub).to have_been_requested
      expect(result).to be_a(Supabase::Auth::Types::UserResponse)
      expect(result.user.email).to eq("test@example.com")
    end

    it "sends POST with user_metadata and app_metadata" do
      attrs = {
        email: "meta@example.com",
        password: "secret123",
        user_metadata: { "profile_image" => "url" },
        app_metadata: { "roles" => ["admin"] }
      }

      stub = stub_request(:post, "#{base_url}/admin/users")
        .with(body: attrs.to_json)
        .to_return(
          status: 200,
          body: { "user" => mock_user_hash }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      admin_api.create_user(**attrs)
      expect(stub).to have_been_requested
    end

    # Python: self._request("POST", "admin/users", body=attributes, xform=parse_user_response)
    it "returns UserResponse matching Python's parse_user_response" do
      stub_request(:post, "#{base_url}/admin/users")
        .to_return(
          status: 200,
          body: { "user" => mock_user_hash }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = admin_api.create_user(email: "new@example.com")
      expect(result).to be_a(Supabase::Auth::Types::UserResponse)
      expect(result.user).to be_a(Supabase::Auth::Types::User)
      expect(result.user.id).to eq(test_uuid)
    end
  end

  # ── AC-2: list_users supports page/per_page pagination params ──

  describe "AC-2: list_users supports page/per_page pagination" do
    it "sends GET to /admin/users without params when none given" do
      stub = stub_request(:get, "#{base_url}/admin/users")
        .to_return(
          status: 200,
          body: { "users" => [mock_user_hash] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = admin_api.list_users
      expect(stub).to have_been_requested
      expect(result).to be_an(Array)
      expect(result.first).to be_a(Supabase::Auth::Types::User)
    end

    it "sends page and per_page as query params" do
      stub = stub_request(:get, "#{base_url}/admin/users")
        .with(query: { "page" => "2", "per_page" => "10" })
        .to_return(
          status: 200,
          body: { "users" => [mock_user_hash] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = admin_api.list_users(page: 2, per_page: 10)
      expect(stub).to have_been_requested
      expect(result.length).to eq(1)
    end

    # Python: query={"page": page, "per_page": per_page} — passes None values
    # Ruby: only includes params if non-nil — functionally equivalent
    it "omits nil pagination params (functionally equivalent to Python None)" do
      stub = stub_request(:get, "#{base_url}/admin/users")
        .with(query: { "page" => "1" })
        .to_return(
          status: 200,
          body: { "users" => [] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = admin_api.list_users(page: 1)
      expect(stub).to have_been_requested
      expect(result).to eq([])
    end

    it "returns empty array when no users key present" do
      stub_request(:get, "#{base_url}/admin/users")
        .to_return(
          status: 200,
          body: {}.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = admin_api.list_users
      expect(result).to eq([])
    end

    # Python: xform=lambda data: [model_validate(User, user) for user in data["users"]]
    it "returns Array<User> matching Python's model_validate transform" do
      stub_request(:get, "#{base_url}/admin/users")
        .to_return(
          status: 200,
          body: { "users" => [mock_user_hash, mock_user_hash] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = admin_api.list_users
      expect(result.length).to eq(2)
      result.each { |u| expect(u).to be_a(Supabase::Auth::Types::User) }
    end
  end

  # ── AC-3: get_user_by_id validates UUID format ──

  describe "AC-3: get_user_by_id validates UUID and sends GET" do
    it "sends GET to /admin/users/{uid} with valid UUID" do
      stub = stub_request(:get, "#{base_url}/admin/users/#{test_uuid}")
        .to_return(
          status: 200,
          body: { "user" => mock_user_hash }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = admin_api.get_user_by_id(test_uuid)
      expect(stub).to have_been_requested
      expect(result).to be_a(Supabase::Auth::Types::UserResponse)
    end

    # Python: self._validate_uuid(uid) raises ValueError("Invalid id, '{id}' is not a valid uuid")
    it "raises ArgumentError for invalid UUID (matches Python ValueError)" do
      expect {
        admin_api.get_user_by_id("not-a-uuid")
      }.to raise_error(ArgumentError, /Invalid id, 'not-a-uuid' is not a valid uuid/)
    end

    it "raises ArgumentError for empty string" do
      expect {
        admin_api.get_user_by_id("")
      }.to raise_error(ArgumentError)
    end

    it "raises ArgumentError for nil" do
      expect {
        admin_api.get_user_by_id(nil)
      }.to raise_error(ArgumentError)
    end
  end

  # ── AC-4: update_user_by_id sends PUT to /admin/users/{uid} ──

  describe "AC-4: update_user_by_id sends PUT to /admin/users/{uid}" do
    it "sends PUT with attributes body" do
      attrs = { email: "updated@example.com" }
      stub = stub_request(:put, "#{base_url}/admin/users/#{test_uuid}")
        .with(body: attrs.to_json)
        .to_return(
          status: 200,
          body: { "user" => mock_user_hash.merge("email" => "updated@example.com") }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = admin_api.update_user_by_id(test_uuid, **attrs)
      expect(stub).to have_been_requested
      expect(result).to be_a(Supabase::Auth::Types::UserResponse)
    end

    it "sends user_metadata and app_metadata in body" do
      attrs = {
        user_metadata: { "favorite_color" => "yellow" },
        app_metadata: { "roles" => %w[admin publisher] }
      }

      stub = stub_request(:put, "#{base_url}/admin/users/#{test_uuid}")
        .with(body: attrs.to_json)
        .to_return(
          status: 200,
          body: { "user" => mock_user_hash }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      admin_api.update_user_by_id(test_uuid, **attrs)
      expect(stub).to have_been_requested
    end

    it "validates UUID before sending request" do
      expect {
        admin_api.update_user_by_id("invalid", email: "test@test.com")
      }.to raise_error(ArgumentError, /Invalid id/)
    end

    it "sends email_confirm attribute" do
      stub = stub_request(:put, "#{base_url}/admin/users/#{test_uuid}")
        .with(body: { email_confirm: true }.to_json)
        .to_return(
          status: 200,
          body: { "user" => mock_user_hash }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      admin_api.update_user_by_id(test_uuid, email_confirm: true)
      expect(stub).to have_been_requested
    end
  end

  # ── AC-5: delete_user supports should_soft_delete parameter ──

  describe "AC-5: delete_user supports should_soft_delete" do
    it "sends DELETE to /admin/users/{uid} with should_soft_delete=false by default" do
      stub = stub_request(:delete, "#{base_url}/admin/users/#{test_uuid}")
        .with(body: { should_soft_delete: false }.to_json)
        .to_return(status: 200, body: "", headers: {})

      admin_api.delete_user(test_uuid)
      expect(stub).to have_been_requested
    end

    # Python: body = {"should_soft_delete": should_soft_delete}
    it "sends should_soft_delete=true when specified" do
      stub = stub_request(:delete, "#{base_url}/admin/users/#{test_uuid}")
        .with(body: { should_soft_delete: true }.to_json)
        .to_return(status: 200, body: "", headers: {})

      admin_api.delete_user(test_uuid, should_soft_delete: true)
      expect(stub).to have_been_requested
    end

    it "validates UUID before sending request" do
      expect {
        admin_api.delete_user("invalid-id")
      }.to raise_error(ArgumentError, /Invalid id/)
    end
  end

  # ── AC-6: invite_user_by_email sends data and redirect_to options ──

  describe "AC-6: invite_user_by_email sends data and redirect_to" do
    it "sends POST to /invite with email and data in body" do
      stub = stub_request(:post, "#{base_url}/invite")
        .with(body: { email: "invite@example.com", data: { "status" => "alpha" } }.to_json)
        .to_return(
          status: 200,
          body: { "user" => mock_user_hash }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      admin_api.invite_user_by_email("invite@example.com", data: { "status" => "alpha" })
      expect(stub).to have_been_requested
    end

    # Python: redirect_to=options.get("redirect_to") — passed as query param via _request
    it "sends redirect_to as query param (matching Python redirect_to kwarg)" do
      stub = stub_request(:post, "#{base_url}/invite")
        .with(
          body: { email: "invite@example.com", data: nil }.to_json,
          query: { "redirect_to" => "http://localhost:9999/welcome" }
        )
        .to_return(
          status: 200,
          body: { "user" => mock_user_hash }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      admin_api.invite_user_by_email("invite@example.com", redirect_to: "http://localhost:9999/welcome")
      expect(stub).to have_been_requested
    end

    it "sends both data and redirect_to" do
      stub = stub_request(:post, "#{base_url}/invite")
        .with(
          body: { email: "invite@example.com", data: { "status" => "alpha" } }.to_json,
          query: { "redirect_to" => "http://localhost:9999/welcome" }
        )
        .to_return(
          status: 200,
          body: { "user" => mock_user_hash }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      admin_api.invite_user_by_email(
        "invite@example.com",
        data: { "status" => "alpha" },
        redirect_to: "http://localhost:9999/welcome"
      )
      expect(stub).to have_been_requested
    end

    it "returns UserResponse" do
      stub_request(:post, "#{base_url}/invite")
        .to_return(
          status: 200,
          body: { "user" => mock_user_hash }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = admin_api.invite_user_by_email("invite@example.com")
      expect(result).to be_a(Supabase::Auth::Types::UserResponse)
    end
  end

  # ── AC-7: generate_link constructs correct body for all link types ──

  describe "AC-7: generate_link constructs correct body" do
    # Python body construction:
    # body = {
    #   "type": params.get("type"),
    #   "email": params.get("email"),
    #   "password": params.get("password"),
    #   "new_email": params.get("new_email"),
    #   "data": params.get("options", {}).get("data"),
    # }
    # redirect_to = params.get("options", {}).get("redirect_to")

    let(:mock_link_response) do
      mock_user_hash.merge(
        "action_link" => "http://localhost:9998/verify?token=abc",
        "email_otp" => "123456",
        "hashed_token" => "hashed-abc",
        "redirect_to" => "http://localhost:9999/welcome",
        "verification_type" => "signup"
      )
    end

    it "constructs signup link body correctly" do
      stub = stub_request(:post, "#{base_url}/admin/generate_link")
        .with(
          body: {
            type: "signup",
            email: "new@example.com",
            password: "secret123",
            new_email: nil,
            data: { "status" => "alpha" }
          }.to_json,
          query: { "redirect_to" => "http://localhost:9999/welcome" }
        )
        .to_return(
          status: 200,
          body: mock_link_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      admin_api.generate_link(
        type: "signup",
        email: "new@example.com",
        password: "secret123",
        options: {
          data: { "status" => "alpha" },
          redirect_to: "http://localhost:9999/welcome"
        }
      )
      expect(stub).to have_been_requested
    end

    it "constructs invite link body correctly" do
      stub = stub_request(:post, "#{base_url}/admin/generate_link")
        .with(
          body: {
            type: "invite",
            email: "invite@example.com",
            password: nil,
            new_email: nil,
            data: nil
          }.to_json
        )
        .to_return(
          status: 200,
          body: mock_link_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      admin_api.generate_link(type: "invite", email: "invite@example.com")
      expect(stub).to have_been_requested
    end

    it "constructs magiclink body correctly" do
      stub = stub_request(:post, "#{base_url}/admin/generate_link")
        .with(
          body: hash_including("type" => "magiclink", "email" => "magic@example.com")
        )
        .to_return(
          status: 200,
          body: mock_link_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      admin_api.generate_link(type: "magiclink", email: "magic@example.com")
      expect(stub).to have_been_requested
    end

    it "constructs recovery link body correctly" do
      stub = stub_request(:post, "#{base_url}/admin/generate_link")
        .with(
          body: hash_including("type" => "recovery", "email" => "recover@example.com")
        )
        .to_return(
          status: 200,
          body: mock_link_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      admin_api.generate_link(type: "recovery", email: "recover@example.com")
      expect(stub).to have_been_requested
    end

    it "constructs email_change_current link with new_email" do
      stub = stub_request(:post, "#{base_url}/admin/generate_link")
        .with(
          body: {
            type: "email_change_current",
            email: "old@example.com",
            password: nil,
            new_email: "new@example.com",
            data: nil
          }.to_json
        )
        .to_return(
          status: 200,
          body: mock_link_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      admin_api.generate_link(
        type: "email_change_current",
        email: "old@example.com",
        new_email: "new@example.com"
      )
      expect(stub).to have_been_requested
    end

    it "constructs email_change_new link with new_email" do
      stub = stub_request(:post, "#{base_url}/admin/generate_link")
        .with(
          body: hash_including("type" => "email_change_new", "new_email" => "new@example.com")
        )
        .to_return(
          status: 200,
          body: mock_link_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      admin_api.generate_link(
        type: "email_change_new",
        email: "old@example.com",
        new_email: "new@example.com"
      )
      expect(stub).to have_been_requested
    end

    it "returns GenerateLinkResponse with properties and user" do
      stub_request(:post, "#{base_url}/admin/generate_link")
        .to_return(
          status: 200,
          body: mock_link_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = admin_api.generate_link(type: "signup", email: "new@example.com", password: "secret123")
      expect(result).to be_a(Supabase::Auth::Types::GenerateLinkResponse)
      expect(result.properties).to be_a(Supabase::Auth::Types::GenerateLinkProperties)
      expect(result.properties.action_link).to eq("http://localhost:9998/verify?token=abc")
      expect(result.properties.email_otp).to eq("123456")
      expect(result.properties.hashed_token).to eq("hashed-abc")
      expect(result.properties.verification_type).to eq("signup")
      expect(result.user).to be_a(Supabase::Auth::Types::User)
    end

    # Python uses redirect_to kwarg on _request; Ruby constructs query manually — both equivalent
    it "passes redirect_to as query param without redirect_to in body" do
      stub = stub_request(:post, "#{base_url}/admin/generate_link")
        .with(query: { "redirect_to" => "http://example.com/callback" })
        .to_return(
          status: 200,
          body: mock_link_response.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      admin_api.generate_link(
        type: "signup",
        email: "new@example.com",
        options: { redirect_to: "http://example.com/callback" }
      )
      expect(stub).to have_been_requested
    end
  end

  # ── AC-8: sign_out sends scope as query param ──

  describe "AC-8: sign_out sends scope as query param with JWT auth" do
    # Python: self._request("POST", "logout", query={"scope": scope}, jwt=jwt, no_resolve_json=True)
    # Ruby:   _request("POST", "logout", jwt: access_token, params: {"scope" => scope}, no_resolve_json: true)

    it "sends POST to /logout with scope=global by default" do
      stub = stub_request(:post, "#{base_url}/logout")
        .with(
          query: { "scope" => "global" },
          headers: { "Authorization" => "Bearer test-access-token" }
        )
        .to_return(status: 204, body: "", headers: {})

      admin_api.sign_out("test-access-token")
      expect(stub).to have_been_requested
    end

    it "sends scope=local as query param" do
      stub = stub_request(:post, "#{base_url}/logout")
        .with(
          query: { "scope" => "local" },
          headers: { "Authorization" => "Bearer test-access-token" }
        )
        .to_return(status: 204, body: "", headers: {})

      admin_api.sign_out("test-access-token", "local")
      expect(stub).to have_been_requested
    end

    it "sends scope=others as query param" do
      stub = stub_request(:post, "#{base_url}/logout")
        .with(
          query: { "scope" => "others" },
          headers: { "Authorization" => "Bearer test-access-token" }
        )
        .to_return(status: 204, body: "", headers: {})

      admin_api.sign_out("test-access-token", "others")
      expect(stub).to have_been_requested
    end

    # FINDING: Python uses jwt= kwarg which auto-sets Authorization header in _request.
    # Ruby also uses jwt: kwarg in _request. Both produce "Authorization: Bearer {jwt}" header.
    it "overrides default Authorization header with jwt param (matching Python jwt= behavior)" do
      stub = stub_request(:post, "#{base_url}/logout")
        .with(
          query: { "scope" => "global" },
          headers: { "Authorization" => "Bearer user-specific-token" }
        )
        .to_return(status: 204, body: "", headers: {})

      admin_api.sign_out("user-specific-token")
      expect(stub).to have_been_requested
    end
  end

  # ── AC-9: Admin MFA _list_factors and _delete_factor ──

  describe "AC-9: Admin MFA _list_factors and _delete_factor" do
    let(:mock_factors) do
      [
        {
          "id" => test_factor_id,
          "friendly_name" => "My TOTP",
          "factor_type" => "totp",
          "status" => "verified",
          "created_at" => "2023-01-01T00:00:00Z",
          "updated_at" => "2023-01-01T00:00:00Z"
        }
      ]
    end

    describe "_list_factors" do
      # Python: self._request("GET", f"admin/users/{params.get('user_id')}/factors", ...)
      it "sends GET to /admin/users/{user_id}/factors" do
        stub = stub_request(:get, "#{base_url}/admin/users/#{test_uuid}/factors")
          .to_return(
            status: 200,
            body: { "factors" => mock_factors }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        result = admin_api._list_factors(user_id: test_uuid)
        expect(stub).to have_been_requested
        expect(result).to be_a(Supabase::Auth::Types::AuthMFAAdminListFactorsResponse)
      end

      it "validates user_id UUID" do
        expect {
          admin_api._list_factors(user_id: "invalid")
        }.to raise_error(ArgumentError, /Invalid id/)
      end

      it "accepts string keys (Ruby extension: supports both symbol and string keys)" do
        stub_request(:get, "#{base_url}/admin/users/#{test_uuid}/factors")
          .to_return(
            status: 200,
            body: { "factors" => mock_factors }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        result = admin_api._list_factors("user_id" => test_uuid)
        expect(result).to be_a(Supabase::Auth::Types::AuthMFAAdminListFactorsResponse)
      end
    end

    describe "_delete_factor" do
      # Python: self._request("DELETE", f"admin/users/{params.get('user_id')}/factors/{params.get('id')}", ...)
      it "sends DELETE to /admin/users/{user_id}/factors/{factor_id}" do
        stub = stub_request(:delete, "#{base_url}/admin/users/#{test_uuid}/factors/#{test_factor_id}")
          .to_return(
            status: 200,
            body: { "id" => test_factor_id }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        result = admin_api._delete_factor(user_id: test_uuid, id: test_factor_id)
        expect(stub).to have_been_requested
        expect(result).to be_a(Supabase::Auth::Types::AuthMFAAdminDeleteFactorResponse)
      end

      it "validates user_id UUID" do
        expect {
          admin_api._delete_factor(user_id: "invalid", id: test_factor_id)
        }.to raise_error(ArgumentError, /Invalid id, 'invalid'/)
      end

      it "validates factor_id UUID" do
        expect {
          admin_api._delete_factor(user_id: test_uuid, id: "invalid")
        }.to raise_error(ArgumentError, /Invalid id, 'invalid'/)
      end

      it "accepts string keys" do
        stub_request(:delete, "#{base_url}/admin/users/#{test_uuid}/factors/#{test_factor_id}")
          .to_return(
            status: 200,
            body: { "id" => test_factor_id }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        result = admin_api._delete_factor("user_id" => test_uuid, "id" => test_factor_id)
        expect(result).to be_a(Supabase::Auth::Types::AuthMFAAdminDeleteFactorResponse)
      end
    end
  end

  # ── Cross-cutting: AdminApi inherits from Api with correct _request behavior ──

  describe "Cross-cutting: AdminApi HTTP behavior" do
    it "includes API version header on requests" do
      stub = stub_request(:post, "#{base_url}/admin/users")
        .with(headers: { "X-Supabase-Api-Version" => "2024-01-01" })
        .to_return(
          status: 200,
          body: { "user" => mock_user_hash }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      admin_api.create_user(email: "test@example.com")
      expect(stub).to have_been_requested
    end

    it "includes Content-Type header" do
      stub = stub_request(:post, "#{base_url}/admin/users")
        .with(headers: { "Content-Type" => "application/json;charset=UTF-8" })
        .to_return(
          status: 200,
          body: { "user" => mock_user_hash }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      admin_api.create_user(email: "test@example.com")
      expect(stub).to have_been_requested
    end

    it "includes Authorization header from initialization" do
      stub = stub_request(:get, "#{base_url}/admin/users")
        .with(headers: { "Authorization" => "Bearer service-role-jwt" })
        .to_return(
          status: 200,
          body: { "users" => [] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      admin_api.list_users
      expect(stub).to have_been_requested
    end
  end
end
