# frozen_string_literal: true

require_relative "version"

module Supabase
  # Structured options passed to {Supabase.create_client} / {Supabase::Client}.
  # Mirrors supabase-py's `SyncClientOptions` / `AsyncClientOptions`. The Ruby
  # port uses one class because the sync/async split is decided at runtime via
  # the `async:` flag on the umbrella client.
  #
  #   opts = Supabase::ClientOptions.new(
  #     schema: "public",
  #     headers: { "X-Tenant" => "acme" },
  #     auto_refresh_token: true,
  #     persist_session: true,
  #     postgrest_client_timeout: 30,
  #     storage_client_timeout: 20,
  #     function_client_timeout: 10,
  #     flow_type: "pkce"
  #   )
  #
  #   Supabase.create_client(supabase_url: url, supabase_key: key, options: opts)
  class ClientOptions
    DEFAULT_POSTGREST_TIMEOUT = 120
    DEFAULT_STORAGE_TIMEOUT   = 20
    DEFAULT_FUNCTIONS_TIMEOUT = 60

    DEFAULT_HEADERS = { "X-Client-Info" => "supabase-rb/#{Supabase::VERSION}" }.freeze

    attr_accessor :schema, :headers, :auto_refresh_token, :persist_session,
                  :realtime, :postgrest_client_timeout, :storage_client_timeout,
                  :function_client_timeout, :flow_type, :storage, :http_client

    def initialize(schema: "public",
                   headers: nil,
                   auto_refresh_token: true,
                   persist_session: true,
                   realtime: nil,
                   postgrest_client_timeout: DEFAULT_POSTGREST_TIMEOUT,
                   storage_client_timeout: DEFAULT_STORAGE_TIMEOUT,
                   function_client_timeout: DEFAULT_FUNCTIONS_TIMEOUT,
                   flow_type: "pkce",
                   storage: nil,
                   http_client: nil)
      @schema                   = schema
      @headers                  = DEFAULT_HEADERS.merge(headers || {})
      @auto_refresh_token       = auto_refresh_token
      @persist_session          = persist_session
      @realtime                 = realtime
      @postgrest_client_timeout = postgrest_client_timeout
      @storage_client_timeout   = storage_client_timeout
      @function_client_timeout  = function_client_timeout
      @flow_type                = flow_type
      @storage                  = storage
      @http_client              = http_client
    end

    # Returns a new ClientOptions with the given fields overridden. Mirrors
    # supabase-py's `replace()` — handy because dataclasses there are frozen
    # at the field-level and we want the same "build then derive" ergonomics.
    def replace(**overrides)
      attrs = to_h.merge(overrides)
      self.class.new(**attrs)
    end

    def to_h
      {
        schema:                   @schema,
        headers:                  @headers,
        auto_refresh_token:       @auto_refresh_token,
        persist_session:          @persist_session,
        realtime:                 @realtime,
        postgrest_client_timeout: @postgrest_client_timeout,
        storage_client_timeout:   @storage_client_timeout,
        function_client_timeout:  @function_client_timeout,
        flow_type:                @flow_type,
        storage:                  @storage,
        http_client:              @http_client
      }
    end
  end
end
