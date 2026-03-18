# frozen_string_literal: true

require "spec_helper"
require "securerandom"

RSpec.describe "Admin API Spec" do
  before(:each) do
    WebMock.allow_net_connect! if defined?(WebMock)
  end

  # auth-py: test_create_user_should_create_a_new_user (test_gotrue_admin_api.py:29)
  it "creates a new user" do
    credentials = mock_user_credentials
    response = create_new_user_with_email(email: credentials[:email])
    expect(response.email).to eq(credentials[:email])
  end

  # auth-py: test_create_user_with_user_metadata (test_gotrue_admin_api.py:35)
  it "creates user with user_metadata" do
    user_metadata = mock_user_metadata
    credentials = mock_user_credentials
    response = service_role_api_client.create_user(
      email: credentials[:email],
      password: credentials[:password],
      user_metadata: user_metadata
    )
    expect(response.user.email).to eq(credentials[:email])
    expect(response.user.user_metadata).to eq(user_metadata.transform_keys(&:to_s))
    expect(response.user.user_metadata).to have_key("profile_image")
  end

  # auth-py: test_create_user_with_user_and_app_metadata (test_gotrue_admin_api.py:50)
  it "creates user with user_metadata and app_metadata" do
    user_metadata = mock_user_metadata
    app_metadata = mock_app_metadata
    credentials = mock_user_credentials
    response = service_role_api_client.create_user(
      email: credentials[:email],
      password: credentials[:password],
      user_metadata: user_metadata,
      app_metadata: app_metadata
    )
    expect(response.user.email).to eq(credentials[:email])
    expect(response.user.user_metadata).to have_key("profile_image")
    expect(response.user.app_metadata).to have_key("provider")
    expect(response.user.app_metadata).to have_key("providers")
  end

  # auth-py: test_create_user_with_app_metadata (test_gotrue_admin_api.py:555)
  it "creates user with app_metadata" do
    app_metadata = mock_app_metadata
    credentials = mock_user_credentials
    response = service_role_api_client.create_user(
      email: credentials[:email],
      password: credentials[:password],
      app_metadata: app_metadata
    )
    expect(response.user.email).to eq(credentials[:email])
    expect(response.user.app_metadata).to have_key("provider")
    expect(response.user.app_metadata).to have_key("providers")
  end

  # auth-py: test_list_users_should_return_registered_users (test_gotrue_admin_api.py:68)
  it "lists users including newly created user" do
    credentials = mock_user_credentials
    create_new_user_with_email(email: credentials[:email])
    users = service_role_api_client.list_users
    expect(users).to be_truthy
    emails = users.map(&:email)
    expect(emails).to include(credentials[:email])
  end

  # auth-py: test_get_user_fetches_a_user_by_their_access_token (test_gotrue_admin_api.py:78)
  it "gets user by access token" do
    credentials = mock_user_credentials
    client = auth_client_with_session
    response = client.sign_up(email: credentials[:email], password: credentials[:password])
    expect(response.session).to be_truthy
    response = client.get_user
    expect(response.user.email).to eq(credentials[:email])
  end

  # auth-py: test_get_user_by_id_should_a_registered_user_given_its_user_identifier (test_gotrue_admin_api.py:92)
  it "gets user by ID" do
    credentials = mock_user_credentials
    user = create_new_user_with_email(email: credentials[:email])
    expect(user.id).to be_truthy
    response = service_role_api_client.get_user_by_id(user.id)
    expect(response.user.email).to eq(credentials[:email])
  end

  # auth-py: test_get_user_by_id_invalid_id_raises_error (test_gotrue_admin_api.py:596)
  it "raises ArgumentError for invalid UUID in get_user_by_id" do
    expect {
      service_role_api_client.get_user_by_id("invalid_id")
    }.to raise_error(ArgumentError, /Invalid id, 'invalid_id' is not a valid uuid/)
  end

  # auth-py: test_modify_email_using_update_user_by_id (test_gotrue_admin_api.py:100)
  it "updates email via update_user_by_id" do
    credentials = mock_user_credentials
    user = create_new_user_with_email(email: credentials[:email])
    response = service_role_api_client.update_user_by_id(
      user.id,
      email: "new_#{user.email}"
    )
    expect(response.user.email).to eq("new_#{user.email}")
  end

  # auth-py: test_modify_user_metadata_using_update_user_by_id (test_gotrue_admin_api.py:112)
  it "updates user_metadata via update_user_by_id" do
    credentials = mock_user_credentials
    user = create_new_user_with_email(email: credentials[:email])
    user_metadata = { "favorite_color" => "yellow" }
    response = service_role_api_client.update_user_by_id(
      user.id,
      user_metadata: user_metadata
    )
    expect(response.user.email).to eq(user.email)
    expect(response.user.user_metadata).to eq(user_metadata)
  end

  # auth-py: test_modify_app_metadata_using_update_user_by_id (test_gotrue_admin_api.py:126)
  it "updates app_metadata via update_user_by_id" do
    credentials = mock_user_credentials
    user = create_new_user_with_email(email: credentials[:email])
    app_metadata = { "roles" => %w[admin publisher] }
    response = service_role_api_client.update_user_by_id(
      user.id,
      app_metadata: app_metadata
    )
    expect(response.user.email).to eq(user.email)
    expect(response.user.app_metadata).to have_key("roles")
  end

  # auth-py: test_modify_confirm_email_using_update_user_by_id (test_gotrue_admin_api.py:140)
  it "confirms email via update_user_by_id" do
    credentials = mock_user_credentials
    response = client_api_auto_confirm_off_signups_enabled_client.sign_up(
      email: credentials[:email],
      password: credentials[:password]
    )
    expect(response.user).to be_truthy
    expect(response.user.email_confirmed_at).to be_nil
    response = service_role_api_client.update_user_by_id(
      response.user.id,
      email_confirm: true
    )
    expect(response.user.email_confirmed_at).to be_truthy
  end

  # auth-py: test_update_user_by_id_invalid_id_raises_error (test_gotrue_admin_api.py:603)
  it "raises ArgumentError for invalid UUID in update_user_by_id" do
    expect {
      service_role_api_client.update_user_by_id("invalid_id", email: "test@test.com")
    }.to raise_error(ArgumentError, /Invalid id, 'invalid_id' is not a valid uuid/)
  end

  # auth-py: test_invalid_credential_sign_in_with_phone (test_gotrue_admin_api.py:159)
  it "raises AuthApiError for invalid phone sign-in" do
    expect {
      client_api_auto_confirm_off_signups_enabled_client.sign_in_with_password(
        phone: "+123456789",
        password: "strong_pwd"
      )
    }.to raise_error(Supabase::Auth::Errors::AuthApiError)
  end

  # auth-py: test_invalid_credential_sign_in_with_email (test_gotrue_admin_api.py:173)
  it "raises AuthApiError for invalid email sign-in" do
    expect {
      client_api_auto_confirm_off_signups_enabled_client.sign_in_with_password(
        email: "unknown_user@unknowndomain.com",
        password: "strong_pwd"
      )
    }.to raise_error(Supabase::Auth::Errors::AuthApiError)
  end

  # auth-py: test_sign_in_with_otp_email (test_gotrue_admin_api.py:187)
  it "raises AuthApiError for email OTP" do
    begin
      client_api_auto_confirm_off_signups_enabled_client.sign_in_with_otp(
        email: "unknown_user@unknowndomain.com"
      )
    rescue Supabase::Auth::Errors::AuthApiError => e
      expect(e.message).to be_truthy
    end
  end

  # auth-py: test_sign_in_with_otp_phone (test_gotrue_admin_api.py:198)
  it "raises AuthApiError for phone OTP" do
    expect {
      client_api_auto_confirm_off_signups_enabled_client.sign_in_with_otp(
        phone: "+112345678"
      )
    }.to raise_error(Supabase::Auth::Errors::AuthApiError)
  end

  # auth-py: test_verify_otp_with_non_existent_phone_number (test_gotrue_admin_api.py:340)
  it "raises AuthError for non-existent phone in verify_otp" do
    otp = mock_verification_otp
    expect {
      client_api_auto_confirm_disabled_client.verify_otp(
        phone: "+1234567890",
        token: otp,
        type: "sms"
      )
    }.to raise_error(Supabase::Auth::Errors::AuthError, /Token has expired or is invalid/)
  end

  # auth-py: test_verify_otp_with_invalid_phone_number (test_gotrue_admin_api.py:356)
  it "raises AuthError for invalid phone format in verify_otp" do
    credentials = mock_user_credentials
    otp = mock_verification_otp
    expect {
      client_api_auto_confirm_disabled_client.verify_otp(
        phone: "#{credentials[:phone]}-invalid",
        token: otp,
        type: "sms"
      )
    }.to raise_error(Supabase::Auth::Errors::AuthError, /Invalid phone number format/)
  end

  # auth-py: test_resend (test_gotrue_admin_api.py:209)
  it "tolerates resend for unregistered phone" do
    begin
      client_api_auto_confirm_off_signups_enabled_client.resend(
        phone: "+112345678",
        type: "sms"
      )
    rescue Supabase::Auth::Errors::AuthApiError => e
      expect(e.message).to be_truthy
    end
  end

  # auth-py: test_resend_missing_credentials (test_gotrue_admin_api.py:242)
  it "raises AuthInvalidCredentialsError for missing resend credentials" do
    expect {
      client_api_auto_confirm_off_signups_enabled_client.resend(
        type: "email_change"
      )
    }.to raise_error(Supabase::Auth::Errors::AuthInvalidCredentialsError)
  end

  # auth-py: test_reauthenticate (test_gotrue_admin_api.py:218)
  it "raises AuthSessionMissingError for reauthenticate without session" do
    expect {
      auth_client_with_session.reauthenticate
    }.to raise_error(Supabase::Auth::Errors::AuthSessionMissing)
  end

  # auth-py: test_refresh_session (test_gotrue_admin_api.py:225)
  it "raises AuthSessionMissingError for refresh_session without session" do
    expect {
      auth_client_with_session.refresh_session
    }.to raise_error(Supabase::Auth::Errors::AuthSessionMissing)
  end

  # auth-py: test_reset_password_for_email (test_gotrue_admin_api.py:232)
  it "raises AuthSessionMissingError for reset_password_email without session" do
    credentials = mock_user_credentials
    expect {
      auth_client_with_session.reset_password_email(email: credentials[:email])
    }.to raise_error(Supabase::Auth::Errors::AuthSessionMissing)
  end

  # auth-py: test_sign_in_anonymously (test_gotrue_admin_api.py:251)
  it "attempts anonymous sign-in tolerating AuthApiError" do
    begin
      response = auth_client_with_session.sign_in_anonymously
      expect(response).to be_truthy
    rescue Supabase::Auth::Errors::AuthApiError
      # Expected — anonymous sign-in may not be enabled
    end
  end

  # auth-py: test_delete_user_should_be_able_delete_an_existing_user (test_gotrue_admin_api.py:259)
  it "deletes user and confirms removal" do
    credentials = mock_user_credentials
    user = create_new_user_with_email(email: credentials[:email])
    service_role_api_client.delete_user(user.id)
    users = service_role_api_client.list_users
    emails = users.map(&:email)
    expect(emails).not_to include(credentials[:email])
  end

  # auth-py: test_delete_user_invalid_id_raises_error (test_gotrue_admin_api.py:612)
  it "raises ArgumentError for invalid UUID in delete_user" do
    expect {
      service_role_api_client.delete_user("invalid_id")
    }.to raise_error(ArgumentError, /Invalid id, 'invalid_id' is not a valid uuid/)
  end

  # auth-py: test_generate_link_supports_sign_up_with_generate_confirmation_signup_link (test_gotrue_admin_api.py:268)
  it "generates signup confirmation link with user_metadata" do
    credentials = mock_user_credentials
    redirect_to = "http://localhost:9999/welcome"
    user_metadata = { "status" => "alpha" }
    response = service_role_api_client.generate_link(
      type: "signup",
      email: credentials[:email],
      password: credentials[:password],
      options: {
        data: user_metadata,
        redirect_to: redirect_to
      }
    )
    expect(response.user.user_metadata).to eq(user_metadata)
  end

  # auth-py: test_generate_link_supports_updating_emails_with_generate_email_change_links (test_gotrue_admin_api.py:286)
  it "generates email change link" do
    credentials = mock_user_credentials
    user = create_new_user_with_email(email: credentials[:email])
    expect(user.email).to be_truthy
    expect(user.email).to eq(credentials[:email])
    new_credentials = mock_user_credentials
    redirect_to = "http://localhost:9999/welcome"
    response = service_role_api_client.generate_link(
      type: "email_change_current",
      email: user.email,
      new_email: new_credentials[:email],
      options: {
        redirect_to: redirect_to
      }
    )
    expect(response.user.new_email).to eq(new_credentials[:email])
  end

  # auth-py: test_invite_user_by_email_creates_a_new_user_with_an_invited_at_timestamp (test_gotrue_admin_api.py:306)
  it "invites user by email with invited_at timestamp" do
    credentials = mock_user_credentials
    redirect_to = "http://localhost:9999/welcome"
    user_metadata = { "status" => "alpha" }
    response = service_role_api_client.invite_user_by_email(
      credentials[:email],
      data: user_metadata,
      redirect_to: redirect_to
    )
    expect(response.user.invited_at).to be_truthy
  end

  # auth-py: test_sign_out_with_an_valid_access_token (test_gotrue_admin_api.py:320)
  it "signs out with valid token" do
    credentials = mock_user_credentials
    response = auth_client_with_session.sign_up(
      email: credentials[:email],
      password: credentials[:password]
    )
    expect(response.session).to be_truthy
    service_role_api_client.sign_out(response.session.access_token)
  end

  # auth-py: test_sign_out_with_an_invalid_access_token (test_gotrue_admin_api.py:332)
  it "raises AuthError for invalid token in sign_out" do
    expect {
      service_role_api_client.sign_out("this-is-a-bad-token")
    }.to raise_error(Supabase::Auth::Errors::AuthError)
  end

  # auth-py: test_sign_in_with_id_token (test_gotrue_admin_api.py:372)
  it "raises AuthApiError for sign_in_with_id_token" do
    expect {
      client_api_auto_confirm_off_signups_enabled_client.sign_in_with_id_token(
        provider: "google",
        token: "123456"
      )
    }.to raise_error(Supabase::Auth::Errors::AuthApiError)
  end

  # auth-py: test_sign_in_with_sso (test_gotrue_admin_api.py:384)
  it "raises AuthApiError with SAML 2.0 disabled message for sign_in_with_sso" do
    expect {
      client_api_auto_confirm_off_signups_enabled_client.sign_in_with_sso(
        domain: "google"
      )
    }.to raise_error(Supabase::Auth::Errors::AuthApiError, /SAML 2.0 is disabled/)
  end

  # auth-py: test_sign_in_with_oauth (test_gotrue_admin_api.py:394)
  it "returns OAuthResponse for sign_in_with_oauth" do
    response = client_api_auto_confirm_off_signups_enabled_client.sign_in_with_oauth(
      provider: "google"
    )
    expect(response).to be_truthy
    expect(response).to be_a(Supabase::Auth::Types::OAuthResponse)
  end

  # auth-py: test_link_identity_missing_session (test_gotrue_admin_api.py:402)
  it "raises AuthSessionMissingError for link_identity without session" do
    expect {
      client_api_auto_confirm_off_signups_enabled_client.link_identity(
        provider: "google"
      )
    }.to raise_error(Supabase::Auth::Errors::AuthSessionMissing)
  end

  # auth-py: test_get_item_from_memory_storage (test_gotrue_admin_api.py:412)
  it "stores session in memory storage after sign-in" do
    credentials = mock_user_credentials
    client = auth_client
    client.sign_up(email: credentials[:email], password: credentials[:password])
    client.sign_in_with_password(email: credentials[:email], password: credentials[:password])
    expect(client._storage.get_item(client._storage_key)).not_to be_nil
  end

  # auth-py: test_remove_item_from_memory_storage (test_gotrue_admin_api.py:431)
  it "removes session from memory storage" do
    credentials = mock_user_credentials
    client = auth_client
    client.sign_up(email: credentials[:email], password: credentials[:password])
    client.sign_in_with_password(email: credentials[:email], password: credentials[:password])
    client._storage.remove_item(client._storage_key)
    expect(client._storage.get_item(client._storage_key)).to be_nil
  end

  # auth-py: test_start_auto_refresh_token (test_gotrue_admin_api.py:472)
  it "starts auto-refresh token timer" do
    credentials = mock_user_credentials
    client = auth_client
    client._auto_refresh_token = true
    client.sign_up(email: credentials[:email], password: credentials[:password])
    client.sign_in_with_password(email: credentials[:email], password: credentials[:password])
    expect(client._start_auto_refresh_token(2.0)).to be_nil
  end

  # auth-py: test_recover_and_refresh (test_gotrue_admin_api.py:493)
  it "recovers and refreshes session from storage" do
    credentials = mock_user_credentials
    client = auth_client
    client._auto_refresh_token = true
    client.sign_up(email: credentials[:email], password: credentials[:password])
    client.sign_in_with_password(email: credentials[:email], password: credentials[:password])
    client._recover_and_refresh
    expect(client._storage.get_item(client._storage_key)).not_to be_nil
  end

  # auth-py: test_list_factors (test_gotrue_admin_api.py:451)
  it "lists factors with totp and phone arrays" do
    credentials = mock_user_credentials
    client = auth_client
    client.sign_up(email: credentials[:email], password: credentials[:password])
    client.sign_in_with_password(email: credentials[:email], password: credentials[:password])
    factors = client._list_factors
    expect(factors).to be_truthy
    expect(factors.totp).to be_a(Array)
    expect(factors.phone).to be_a(Array)
  end

  # auth-py: test_get_user_identities (test_gotrue_admin_api.py:514)
  it "gets user identities with email in identity_data" do
    credentials = mock_user_credentials
    client = auth_client
    client.sign_up(email: credentials[:email], password: credentials[:password])
    client.sign_in_with_password(email: credentials[:email], password: credentials[:password])
    identities_response = client.get_user_identities
    expect(identities_response.identities[0].identity_data["email"]).to eq(credentials[:email])
  end

  # auth-py: test_update_user (test_gotrue_admin_api.py:536)
  it "updates user password and signs in with new password" do
    credentials = mock_user_credentials
    client = auth_client
    client.sign_up(email: credentials[:email], password: credentials[:password])
    client.update_user(password: "123e5a")
    client.sign_in_with_password(email: credentials[:email], password: "123e5a")
  end

  # auth-py: test_list_factors_invalid_id_raises_error (test_gotrue_admin_api.py:619)
  it "raises ArgumentError for invalid UUID in admin list_factors" do
    expect {
      service_role_api_client._list_factors(user_id: "invalid_id")
    }.to raise_error(ArgumentError, /Invalid id, 'invalid_id' is not a valid uuid/)
  end

  # auth-py: test_delete_factor_invalid_id_raises_error (test_gotrue_admin_api.py:626)
  it "raises ArgumentError for invalid user_id or factor_id in admin delete_factor" do
    # invalid user id
    expect {
      service_role_api_client._delete_factor(user_id: "invalid_id", id: "invalid_id")
    }.to raise_error(ArgumentError, /Invalid id, 'invalid_id' is not a valid uuid/)

    # valid user id, invalid factor id
    expect {
      service_role_api_client._delete_factor(user_id: SecureRandom.uuid, id: "invalid_id")
    }.to raise_error(ArgumentError, /Invalid id, 'invalid_id' is not a valid uuid/)
  end

  # auth-py: test_weak_email_password_error (test_gotrue_admin_api.py:570)
  # Python catches (AuthWeakPasswordError, AuthApiError) — both are subclasses of AuthError
  it "raises weak password error for email signup with short password" do
    credentials = mock_user_credentials
    begin
      client_api_auto_confirm_off_signups_enabled_client.sign_up(
        email: credentials[:email],
        password: "123"
      )
      raise "Expected AuthWeakPasswordError or AuthApiError"
    rescue Supabase::Auth::Errors::AuthWeakPassword, Supabase::Auth::Errors::AuthApiError => e
      expect(e.to_h).to be_a(Hash)
    end
  end

  # auth-py: test_weak_phone_password_error (test_gotrue_admin_api.py:583)
  # Python catches (AuthWeakPasswordError, AuthApiError) — both are subclasses of AuthError
  it "raises weak password error for phone signup with short password" do
    credentials = mock_user_credentials
    begin
      client_api_auto_confirm_off_signups_enabled_client.sign_up(
        phone: credentials[:phone],
        password: "123"
      )
      raise "Expected AuthWeakPasswordError or AuthApiError"
    rescue Supabase::Auth::Errors::AuthWeakPassword, Supabase::Auth::Errors::AuthApiError => e
      expect(e.to_h).to be_a(Hash)
    end
  end
end
