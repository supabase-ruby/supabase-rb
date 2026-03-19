# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Utils" do
  before(:each) do
    WebMock.allow_net_connect! if defined?(WebMock)
  end

  # Ported from: test_mock_user_credentials_has_email
  it "generates credentials with email and password" do
    credentials = mock_user_credentials
    expect(credentials[:email]).to be_truthy
    expect(credentials[:password]).to be_truthy
  end

  # Ported from: test_mock_user_credentials_has_phone
  it "generates credentials with phone and password" do
    credentials = mock_user_credentials
    expect(credentials[:phone]).to be_truthy
    expect(credentials[:password]).to be_truthy
  end

  # Ported from: test_create_new_user_with_email
  it "creates a new user via admin API" do
    email = "user+#{Time.now.to_i}_#{rand(100_000)}@example.com"
    user = create_new_user_with_email(email: email)
    expect(user.email).to eq(email)
  end

  # Ported from: test_mock_user_metadata
  it "generates user_metadata with profile_image" do
    user_metadata = mock_user_metadata
    expect(user_metadata).to be_truthy
    expect(user_metadata[:profile_image]).to be_truthy
  end

  # Ported from: test_mock_app_metadata
  it "generates app_metadata with roles" do
    app_metadata = mock_app_metadata
    expect(app_metadata).to be_truthy
    expect(app_metadata[:roles]).to be_truthy
  end
end
