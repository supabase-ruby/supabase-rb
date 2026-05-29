# frozen_string_literal: true

require_relative "supabase/version"
require_relative "supabase/client_options"
require_relative "supabase/client"

module Supabase
  # Re-exports of error types from each sub-library, so callers can rescue with
  # the umbrella names that mirror supabase-py's top-level `__init__.py`:
  #
  #   rescue Supabase::PostgrestAPIError       => e   # postgrest
  #   rescue Supabase::StorageException        => e   # storage
  #   rescue Supabase::AuthApiError            => e   # auth
  #   rescue Supabase::FunctionsHttpError      => e   # functions
  #   rescue Supabase::AuthorizationError      => e   # realtime
  #
  # The actual classes live in their sub-namespaces; these are aliases.

  # Postgrest
  PostgrestAPIError    = Postgrest::Errors::APIError    if defined?(Postgrest::Errors::APIError)
  PostgrestAPIResponse = Postgrest::APIResponse         if defined?(Postgrest::APIResponse)

  # Storage
  StorageException = Storage::Errors::StorageError      if defined?(Storage::Errors::StorageError)
  StorageApiError  = Storage::Errors::StorageApiError   if defined?(Storage::Errors::StorageApiError)

  # Auth (supabase_auth.errors.*)
  if defined?(Auth::Errors)
    AuthError                        = Auth::Errors::AuthError                        if defined?(Auth::Errors::AuthError)
    AuthApiError                     = Auth::Errors::AuthApiError                     if defined?(Auth::Errors::AuthApiError)
    AuthImplicitGrantRedirectError   = Auth::Errors::AuthImplicitGrantRedirectError   if defined?(Auth::Errors::AuthImplicitGrantRedirectError)
    AuthInvalidCredentialsError      = Auth::Errors::AuthInvalidCredentialsError      if defined?(Auth::Errors::AuthInvalidCredentialsError)
    AuthRetryableError               = Auth::Errors::AuthRetryableError               if defined?(Auth::Errors::AuthRetryableError)
    AuthSessionMissingError          = Auth::Errors::AuthSessionMissingError          if defined?(Auth::Errors::AuthSessionMissingError)
    AuthUnknownError                 = Auth::Errors::AuthUnknownError                 if defined?(Auth::Errors::AuthUnknownError)
    AuthWeakPasswordError            = Auth::Errors::AuthWeakPasswordError            if defined?(Auth::Errors::AuthWeakPasswordError)
  end

  # Functions
  if defined?(Functions::Errors)
    FunctionsError      = Functions::Errors::FunctionsError      if defined?(Functions::Errors::FunctionsError)
    FunctionsHttpError  = Functions::Errors::FunctionsHttpError  if defined?(Functions::Errors::FunctionsHttpError)
    FunctionsRelayError = Functions::Errors::FunctionsRelayError if defined?(Functions::Errors::FunctionsRelayError)
  end

  # Realtime
  if defined?(Realtime::Errors)
    AuthorizationError = Realtime::Errors::AuthorizationError if defined?(Realtime::Errors::AuthorizationError)
    NotConnectedError  = Realtime::Errors::NotConnectedError  if defined?(Realtime::Errors::NotConnectedError)
  end

  # Raised by {Supabase.create_client} on a missing url/key. Mirrors py's
  # `SupabaseException`. We don't inherit from a sub-library error because the
  # umbrella factory predates choosing any of them.
  class SupabaseException < StandardError; end

  # Alias mirroring supabase-py's `acreate_client` / `create_async_client`.
  # Equivalent to `create_client(..., async: true)`.
  def self.acreate_client(supabase_url:, supabase_key:, options: {})
    create_client(supabase_url: supabase_url, supabase_key: supabase_key, options: options, async: true)
  end
  singleton_class.send(:alias_method, :create_async_client, :acreate_client)
end
