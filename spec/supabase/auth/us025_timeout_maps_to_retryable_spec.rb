# frozen_string_literal: true

require "spec_helper"
require "faraday"

# US-025: Auth Faraday timeout → AuthRetryableError (F-C10 — part 3)
# Pins the contract that a `Faraday::TimeoutError` (raised by the transport
# before any response object is constructed) is mapped to `AuthRetryableError`
# by `Helpers.handle_exception`, rather than slipping through to
# `AuthUnknownError` (which is what the bare `response[:status]` access used to
# trigger when `exception.response` was nil).
RSpec.describe "US-025: Faraday timeout → AuthRetryableError" do
  it "maps Faraday::TimeoutError to AuthRetryableError" do
    exception = Faraday::TimeoutError.new("execution expired")

    result = Supabase::Auth::Helpers.handle_exception(exception)

    expect(result).to be_a(Supabase::Auth::Errors::AuthRetryableError)
    expect(result.status).to eq(0)
    expect(result.message).to include("execution expired")
  end

  it "maps a TimeoutError carrying a nil response to AuthRetryableError" do
    exception = Faraday::TimeoutError.new("execution expired", nil)

    result = Supabase::Auth::Helpers.handle_exception(exception)

    expect(result).to be_a(Supabase::Auth::Errors::AuthRetryableError)
    expect(result.status).to eq(0)
  end

  it "maps a ServerError with a nil response to AuthRetryableError" do
    exception = Faraday::ServerError.new("connection reset", nil)

    result = Supabase::Auth::Helpers.handle_exception(exception)

    expect(result).to be_a(Supabase::Auth::Errors::AuthRetryableError)
    expect(result.status).to eq(0)
  end

  it "maps a ClientError with a nil response to AuthRetryableError" do
    exception = Faraday::ClientError.new("malformed response", nil)

    result = Supabase::Auth::Helpers.handle_exception(exception)

    expect(result).to be_a(Supabase::Auth::Errors::AuthRetryableError)
    expect(result.status).to eq(0)
  end

  it "raises AuthRetryableError end-to-end when the Faraday adapter raises Faraday::TimeoutError" do
    base_url = "http://localhost:9998"
    api = Supabase::Auth::Api.new(url: base_url, headers: { "apikey" => "test-key" })

    allow_any_instance_of(Faraday::Connection)
      .to receive(:run_request)
      .and_raise(Faraday::TimeoutError.new("execution expired"))

    expect { api.get("/user") }.to raise_error(Supabase::Auth::Errors::AuthRetryableError) do |e|
      expect(e.status).to eq(0)
    end
  end
end
