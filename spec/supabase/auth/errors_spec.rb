# frozen_string_literal: true

RSpec.describe Supabase::Auth::Errors do
  describe Supabase::Auth::Errors::AuthError do
    it "inherits from StandardError" do
      expect(Supabase::Auth::Errors::AuthError).to be < StandardError
    end

    it "has status and code attributes" do
      error = described_class.new("something failed", status: 500, code: "unexpected_failure")
      expect(error.message).to eq("something failed")
      expect(error.status).to eq(500)
      expect(error.code).to eq("unexpected_failure")
    end

    it "defaults status and code to nil" do
      error = described_class.new("generic error")
      expect(error.status).to be_nil
      expect(error.code).to be_nil
    end
  end

  describe Supabase::Auth::Errors::AuthApiError do
    it "inherits from AuthError" do
      expect(described_class).to be < Supabase::Auth::Errors::AuthError
    end

    it "requires status and sets code" do
      error = described_class.new("Not found", status: 404, code: "user_not_found")
      expect(error.message).to eq("Not found")
      expect(error.status).to eq(404)
      expect(error.code).to eq("user_not_found")
    end

    it "defaults code to nil" do
      error = described_class.new("Server error", status: 500)
      expect(error.status).to eq(500)
      expect(error.code).to be_nil
    end
  end

  describe Supabase::Auth::Errors::AuthInvalidJwtError do
    it "inherits from AuthError" do
      expect(described_class).to be < Supabase::Auth::Errors::AuthError
    end

    it "sets status to 400 and code to invalid_jwt" do
      error = described_class.new("JWT expired")
      expect(error.message).to eq("JWT expired")
      expect(error.status).to eq(400)
      expect(error.code).to eq("invalid_jwt")
    end
  end

  describe Supabase::Auth::Errors::AuthSessionMissing do
    it "inherits from AuthError" do
      expect(described_class).to be < Supabase::Auth::Errors::AuthError
    end

    it "has a default message" do
      error = described_class.new
      expect(error.message).to eq("Auth session missing!")
      expect(error.status).to eq(400)
    end

    it "accepts a custom message" do
      error = described_class.new("No session found")
      expect(error.message).to eq("No session found")
    end
  end

  describe Supabase::Auth::Errors::AuthWeakPassword do
    it "inherits from AuthError" do
      expect(described_class).to be < Supabase::Auth::Errors::AuthError
    end

    it "has reasons attribute" do
      error = described_class.new("Password too weak", reasons: ["too short", "no special chars"])
      expect(error.message).to eq("Password too weak")
      expect(error.code).to eq("weak_password")
      expect(error.reasons).to eq(["too short", "no special chars"])
      expect(error.status).to eq(422)
    end

    it "defaults reasons to empty array" do
      error = described_class.new("Weak")
      expect(error.reasons).to eq([])
    end
  end

  describe Supabase::Auth::Errors::AuthPKCEError do
    it "inherits from AuthError" do
      expect(described_class).to be < Supabase::Auth::Errors::AuthError
    end

    it "sets status and code" do
      error = described_class.new("Code verifier mismatch")
      expect(error.message).to eq("Code verifier mismatch")
      expect(error.status).to eq(400)
      expect(error.code).to eq("pkce_error")
    end
  end

  describe Supabase::Auth::Errors::AuthUnknownError do
    it "inherits from AuthError" do
      expect(described_class).to be < Supabase::Auth::Errors::AuthError
    end

    it "wraps an original error" do
      original = RuntimeError.new("boom")
      error = described_class.new("Unexpected error", original_error: original)
      expect(error.message).to eq("Unexpected error")
      expect(error.original_error).to eq(original)
      expect(error.status).to be_nil
      expect(error.code).to be_nil
    end
  end

  it "all error classes can be rescued as AuthError" do
    error_classes = [
      Supabase::Auth::Errors::AuthApiError,
      Supabase::Auth::Errors::AuthInvalidJwtError,
      Supabase::Auth::Errors::AuthSessionMissing,
      Supabase::Auth::Errors::AuthWeakPassword,
      Supabase::Auth::Errors::AuthPKCEError,
      Supabase::Auth::Errors::AuthUnknownError
    ]

    error_classes.each do |klass|
      expect(klass).to be < Supabase::Auth::Errors::AuthError
    end
  end
end
