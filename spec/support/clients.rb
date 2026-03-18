# frozen_string_literal: true

require "jwt"

module TestClients
  SIGNUP_ENABLED_AUTO_CONFIRM_OFF_PORT = 9999
  SIGNUP_ENABLED_AUTO_CONFIRM_ON_PORT = 9998
  SIGNUP_DISABLED_AUTO_CONFIRM_OFF_PORT = 9997
  SIGNUP_ENABLED_ASYMMETRIC_AUTO_CONFIRM_ON_PORT = 9996

  GOTRUE_URL_SIGNUP_ENABLED_AUTO_CONFIRM_OFF =
    "http://localhost:#{SIGNUP_ENABLED_AUTO_CONFIRM_OFF_PORT}"
  GOTRUE_URL_SIGNUP_ENABLED_AUTO_CONFIRM_ON =
    "http://localhost:#{SIGNUP_ENABLED_AUTO_CONFIRM_ON_PORT}"
  GOTRUE_URL_SIGNUP_ENABLED_ASYMMETRIC_AUTO_CONFIRM_ON =
    "http://localhost:#{SIGNUP_ENABLED_ASYMMETRIC_AUTO_CONFIRM_ON_PORT}"
  GOTRUE_URL_SIGNUP_DISABLED_AUTO_CONFIRM_OFF =
    "http://localhost:#{SIGNUP_DISABLED_AUTO_CONFIRM_OFF_PORT}"

  GOTRUE_JWT_SECRET = "37c304f8-51aa-419a-a1af-06154e63707a"

  AUTH_ADMIN_JWT = JWT.encode(
    { "sub" => "1234567890", "role" => "supabase_admin" },
    GOTRUE_JWT_SECRET,
    "HS256"
  )

  SERVICE_ROLE_JWT = JWT.encode(
    { "role" => "service_role" },
    GOTRUE_JWT_SECRET,
    "HS256"
  )

  # --- Regular clients (1-7) using Supabase::Auth::Client ---

  def auth_client
    Supabase::Auth::Client.new(
      url: GOTRUE_URL_SIGNUP_ENABLED_AUTO_CONFIRM_ON,
      auto_refresh_token: false,
      persist_session: true
    )
  end

  def auth_client_with_session
    Supabase::Auth::Client.new(
      url: GOTRUE_URL_SIGNUP_ENABLED_AUTO_CONFIRM_ON,
      auto_refresh_token: false,
      persist_session: false
    )
  end

  def auth_client_with_asymmetric_session
    Supabase::Auth::Client.new(
      url: GOTRUE_URL_SIGNUP_ENABLED_ASYMMETRIC_AUTO_CONFIRM_ON,
      auto_refresh_token: false,
      persist_session: false
    )
  end

  def auth_subscription_client
    Supabase::Auth::Client.new(
      url: GOTRUE_URL_SIGNUP_ENABLED_AUTO_CONFIRM_ON,
      auto_refresh_token: false,
      persist_session: true
    )
  end

  def client_api_auto_confirm_enabled_client
    Supabase::Auth::Client.new(
      url: GOTRUE_URL_SIGNUP_ENABLED_AUTO_CONFIRM_ON,
      auto_refresh_token: false,
      persist_session: true
    )
  end

  def client_api_auto_confirm_off_signups_enabled_client
    Supabase::Auth::Client.new(
      url: GOTRUE_URL_SIGNUP_ENABLED_AUTO_CONFIRM_OFF,
      auto_refresh_token: false,
      persist_session: true
    )
  end

  def client_api_auto_confirm_disabled_client
    Supabase::Auth::Client.new(
      url: GOTRUE_URL_SIGNUP_DISABLED_AUTO_CONFIRM_OFF,
      auto_refresh_token: false,
      persist_session: true
    )
  end

  # --- Admin clients (8-12) using Supabase::Auth::AdminApi ---

  def auth_admin_api_auto_confirm_enabled_client
    Supabase::Auth::AdminApi.new(
      url: GOTRUE_URL_SIGNUP_ENABLED_AUTO_CONFIRM_ON,
      headers: { "Authorization" => "Bearer #{AUTH_ADMIN_JWT}" }
    )
  end

  def auth_admin_api_auto_confirm_disabled_client
    Supabase::Auth::AdminApi.new(
      url: GOTRUE_URL_SIGNUP_ENABLED_AUTO_CONFIRM_OFF,
      headers: { "Authorization" => "Bearer #{AUTH_ADMIN_JWT}" }
    )
  end

  def service_role_api_client
    Supabase::Auth::AdminApi.new(
      url: GOTRUE_URL_SIGNUP_ENABLED_AUTO_CONFIRM_ON,
      headers: { "Authorization" => "Bearer #{SERVICE_ROLE_JWT}" }
    )
  end

  def service_role_api_client_with_sms
    Supabase::Auth::AdminApi.new(
      url: GOTRUE_URL_SIGNUP_ENABLED_AUTO_CONFIRM_OFF,
      headers: { "Authorization" => "Bearer #{SERVICE_ROLE_JWT}" }
    )
  end

  def service_role_api_client_no_sms
    Supabase::Auth::AdminApi.new(
      url: GOTRUE_URL_SIGNUP_DISABLED_AUTO_CONFIRM_OFF,
      headers: { "Authorization" => "Bearer #{SERVICE_ROLE_JWT}" }
    )
  end
end

RSpec.configure do |config|
  config.include TestClients
end
