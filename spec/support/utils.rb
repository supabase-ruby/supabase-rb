# frozen_string_literal: true

require "faker"
require "jwt"

module TestUtils
  # Returns a JWT with {sub: "1234567890", role: "anon_key"} signed with GOTRUE_JWT_SECRET
  def mock_access_token
    JWT.encode(
      { "sub" => "1234567890", "role" => "anon_key" },
      TestClients::GOTRUE_JWT_SECRET,
      "HS256"
    )
  end

  # Generates unique credentials each call using Faker.
  # Phone numbers use "1#{rand_numbers[-11:]}" matching auth-py logic.
  # @param options [Hash] Optional overrides for :email, :phone, :password
  # @return [Hash] with :email, :phone, :password keys
  def mock_user_credentials(options = {})
    rand_numbers = Time.now.to_i.to_s
    {
      email: options[:email] || Faker::Internet.email,
      phone: options[:phone] || "1#{rand_numbers[-11..]}",
      password: options[:password] || Faker::Internet.password
    }
  end

  # Returns a random 6-digit OTP string
  def mock_verification_otp
    (100_000 + rand * 900_000).to_i.to_s
  end

  # Returns { profile_image: <random_url> }
  def mock_user_metadata
    { profile_image: Faker::Internet.url }
  end

  # Returns { roles: ["editor", "publisher"] }
  def mock_app_metadata
    { roles: %w[editor publisher] }
  end

  # Creates a real user in GoTrue via the admin API.
  # @param email [String, nil] Optional email override
  # @param password [String, nil] Optional password override
  # @return [Supabase::Auth::Types::User]
  def create_new_user_with_email(email: nil, password: nil)
    credentials = mock_user_credentials(email: email, password: password)
    response = service_role_api_client.create_user(
      email: credentials[:email],
      password: credentials[:password]
    )
    response.user
  end
end

RSpec.configure do |config|
  config.include TestUtils
end
