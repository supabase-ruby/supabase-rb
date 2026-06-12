# frozen_string_literal: true

require "uri"

require_relative "auth"
require_relative "postgrest"
require_relative "storage"
require_relative "functions"
require_relative "realtime"

module Supabase
  # Top-level client that combines every sub-library behind one object, mirroring
  # supabase-py's `supabase.create_client()`.
  #
  #   client = Supabase.create_client(
  #     supabase_url: "https://project.supabase.co",
  #     supabase_key: ENV["SUPABASE_ANON_KEY"]
  #   )
  #
  #   client.auth.sign_in_with_password(email:, password:)
  #   users = client.from("users").select("*").execute
  #   client.storage.from("avatars").upload("a.png", bytes)
  #   client.functions.invoke("hello-world", body: { name: "Ada" })
  #   ch = client.realtime.channel("realtime:public:users")
  #
  # Sub-clients are built lazily and memoized. Pass `async: true` to swap in the
  # async-http-faraday variants for Auth / Postgrest / Storage / Functions; the
  # Realtime client is transport-agnostic and ships sync regardless (a real WS
  # transport is wired in by the caller — see lib/supabase/realtime/socket.rb).
  class Client
    attr_reader :supabase_url, :supabase_key, :options, :headers

    # Mirrors supabase-py's `Client.create(...)`: builds a client, then — if
    # no explicit Authorization was supplied via options — tries to pull a
    # persisted session via the auth client and applies its access_token as
    # the bearer token. Useful when bootstrapping from a session file the
    # user previously signed into. Any error from get_session is swallowed
    # so the client always returns successfully.
    def self.create(supabase_url:, supabase_key:, options: nil, async: false)
      configured_auth = nil
      if options.is_a?(Supabase::ClientOptions)
        configured_auth = options.headers["Authorization"] || options.headers[:Authorization]
      elsif options.is_a?(Hash)
        configured_headers = options[:global]&.dig(:headers) || options.dig("global", "headers") ||
                             options[:headers] || options["headers"] || {}
        configured_auth = configured_headers["Authorization"] || configured_headers[:Authorization]
      end

      client = new(supabase_url: supabase_url, supabase_key: supabase_key,
                   options: options || {}, async: async)

      if configured_auth.nil?
        begin
          session = client.auth.get_session
          client.set_auth(session.access_token) if session&.access_token
        rescue StandardError
          # No persisted session, or auth storage unavailable — fall back to
          # the apikey-only bearer that initialize set up.
        end
      end

      client
    end

    def initialize(supabase_url:, supabase_key:, options: {}, async: false)
      # Use Supabase::SupabaseException once defined; fall back to ArgumentError
      # during early require cycles. Matches supabase-py's contract.
      err = defined?(Supabase::SupabaseException) ? Supabase::SupabaseException : ArgumentError
      raise err, "supabase_url is required" if supabase_url.to_s.empty?
      raise err, "supabase_key is required" if supabase_key.to_s.empty?
      raise err, "Invalid URL" unless supabase_url.to_s.match?(%r{^https?://.+})

      @supabase_url = supabase_url.to_s.chomp("/")
      @supabase_key = supabase_key
      # Plain Hash → ClientOptions: paritet with supabase-py, where every
      # option flows through a typed dataclass. The legacy nested
      # `{ auth: {...}, postgrest: {...}, global: { headers: {...} } }` shape
      # is kept as a raw Hash so existing callers don't break — anything
      # else is canonicalized into a ClientOptions struct so the per-sub-
      # client kwargs derivation has one code path.
      legacy_hash_shape = options.is_a?(Hash) && legacy_options_hash?(options)
      warn_stray_legacy_keys(options) if legacy_hash_shape

      @options =
        if options.is_a?(Hash) && !legacy_hash_shape
          ClientOptions.new(**options.transform_keys(&:to_sym))
        elsif options.is_a?(Supabase::ClientOptions)
          # Mirror supabase-py's `self.options = copy.copy(options)` followed by
          # `self.options.headers = {**options.headers, ...}` — both the struct
          # and its headers hash become unique to this client, so a downstream
          # `client.options.headers["X"] = ...` mutation can't leak across
          # clients constructed from the same `ClientOptions` instance (F-C?).
          isolated = options.dup
          isolated.headers = isolated.headers.dup
          isolated
        else
          options
        end
      @async        = async

      configured_headers =
        if @options.is_a?(Supabase::ClientOptions)
          @options.headers
        else
          @options[:global]&.dig(:headers) || @options.dig("global", "headers") || {}
        end

      @headers = {
        "apikey"        => @supabase_key,
        "Authorization" => "Bearer #{@supabase_key}"
      }.merge(configured_headers || {})

      # Current access token used to authorize the data-plane sub-clients
      # (postgrest/storage/functions) and the realtime socket. Starts as the
      # anon key and is rotated by #apply_auth on sign-in / token refresh. Held
      # explicitly (rather than re-derived from @headers) so that a realtime
      # client built LAZILY after a sign-in still picks up the session token
      # instead of the anon key — see #realtime.
      @access_token = @supabase_key
    end

    def async?
      @async
    end

    # --- Sub-clients ---------------------------------------------------------

    def auth
      return @auth if @auth

      @auth = auth_class.new(url: rest_url_for("auth/v1"), headers: @headers, **sub_options(:auth))
      # Mirror supabase-py's `self.auth.on_auth_state_change(self._listen_to_auth_events)`:
      # when the auth client emits SIGNED_IN / TOKEN_REFRESHED / SIGNED_OUT,
      # propagate the new token to every other sub-client.
      @auth.on_auth_state_change do |event, session|
        next unless %w[SIGNED_IN TOKEN_REFRESHED SIGNED_OUT].include?(event)

        apply_auth(session&.access_token)
      end
      @auth
    end

    def storage
      @storage ||= storage_class.new(base_url: rest_url_for("storage/v1"), headers: @headers,
                                     **sub_options(:storage))
    end

    def functions
      @functions ||= functions_class.new(base_url: rest_url_for("functions/v1"), headers: @headers,
                                         **sub_options(:functions))
    end

    def realtime
      # Use the current access token (@access_token), not the anon key: if the
      # caller signed in before this lazy accessor first ran, apply_auth could
      # not push the token to a not-yet-built realtime client, so we must seed
      # the join auth from the rotated token here. apikey stays the anon key.
      @realtime ||= Realtime::Client.new(
        url:    realtime_url,
        params: { "apikey" => @supabase_key, "access_token" => @access_token },
        **sub_options(:realtime)
      )
    end

    # PostgREST is the only sub-library where the public API is reached via a
    # bare method on the umbrella (`client.from('users')`) rather than a named
    # accessor. We expose both for explicitness.
    def postgrest
      @postgrest ||= postgrest_class.new(base_url: rest_url_for("rest/v1"), headers: @headers,
                                         **sub_options(:postgrest))
    end

    def from(table)
      postgrest.from(table)
    end

    # Alias for {#from}. Mirrors supabase-py's `Client.table(table_name)` so
    # code ported from Python (`client.table("users").select("*")`) works
    # unchanged.
    # @see supabase-py supabase/_sync/client.py:128
    alias table from

    def rpc(func, params = {}, **opts)
      postgrest.rpc(func, params, **opts)
    end

    # Realtime shortcuts on the umbrella — mirror supabase-py so callers can do
    # `client.channel("public:users")` instead of `client.realtime.channel(...)`.
    # The `realtime:` topic prefix is still optional (handled inside the
    # Realtime client).
    def channel(topic, params: nil)
      realtime.channel(topic, params: params)
    end

    def get_channels
      realtime.get_channels
    end

    # Unsubscribe a channel and drop it from the realtime registry. Mirrors
    # supabase-py: the sync client blocks until the phx_leave frame is written;
    # the async client (`async def remove_channel`) lets callers await it.
    # Under `async: true` we get the same shape via {#dispatch_realtime} — the
    # call returns an `Async::Task` the caller may `.wait` on (US-050), so a
    # slow `Socket#send` never stalls the calling fiber.
    # @see supabase-py supabase/_async/client.py:231
    def remove_channel(channel)
      dispatch_realtime { realtime.remove_channel(channel) }
    end

    # Unsubscribe every realtime channel registered on this client. Mirrors
    # supabase-py's `Client.remove_all_channels`; same sync/async contract as
    # {#remove_channel}.
    # @see supabase-py supabase/_sync/client.py:234
    def remove_all_channels
      dispatch_realtime { realtime.remove_all_channels }
    end

    # Return a Postgrest client scoped to `name` without mutating self. Matches
    # supabase-py: `client.schema("foo").from_("x")` queries the foo schema but
    # leaves `client.from(...)` (and other call sites) on the default schema.
    def schema(name)
      postgrest.schema(name)
    end

    # --- Shared auth context -------------------------------------------------

    # Update the Authorization header used by every sub-client. Useful after
    # auth.sign_in returns a fresh JWT — the apikey stays the same but the
    # bearer token becomes the user's access token.
    #
    # Breaking change vs <=3.1.1: `set_auth(nil)` no longer drops the memoized
    # auth sub-client (and with it any persisted session). Call `auth.sign_out`
    # to clear session state.
    def set_auth(token)
      apply_auth(token)
      self
    end

    private

    # Keys that only occur in the legacy nested options shape — none of them
    # is a ClientOptions field, so their presence is an unambiguous marker.
    # `:storage` and `:realtime` are deliberately NOT in this list: both are
    # also ClientOptions fields and need value-based disambiguation below.
    LEGACY_ONLY_OPTION_KEYS = %i[auth postgrest functions global].freeze
    # Every key the legacy nested shape consumes; anything else passed
    # alongside one of these is silently invisible to the sub-clients.
    LEGACY_OPTION_KEYS = (LEGACY_ONLY_OPTION_KEYS + %i[storage realtime]).freeze
    private_constant :LEGACY_ONLY_OPTION_KEYS, :LEGACY_OPTION_KEYS

    def legacy_options_hash?(options)
      return true if options.keys.any? { |k| LEGACY_ONLY_OPTION_KEYS.include?(k.to_sym) }

      # `:storage` exists in both shapes. A Hash can only be the legacy
      # per-sub-client kwargs — the ClientOptions field holds a session
      # storage *object* (get_item/set_item duck type), never a Hash.
      #
      # `:realtime` is a kwargs Hash in both shapes and both code paths hand
      # it to Realtime::Client unchanged, so on its own it is not a legacy
      # marker — routing it through ClientOptions keeps sibling fields like
      # `:schema` from being silently dropped.
      option_value(options, :storage).is_a?(Hash)
    end

    def option_value(options, key)
      options.key?(key) ? options[key] : options[key.to_s]
    end

    # The legacy shape only routes its known nested keys; flat ClientOptions
    # fields mixed in (e.g. `{ schema: "x", auth: {...} }`) never reach any
    # sub-client. Losing them silently was the original failure mode of the
    # shape detector, so make the remaining ambiguous case loud.
    def warn_stray_legacy_keys(options)
      stray = options.keys.map(&:to_sym) - LEGACY_OPTION_KEYS
      return if stray.empty?

      warn "Supabase::Client: options #{stray.inspect} are ignored when combined with the " \
           "legacy nested options shape (#{LEGACY_OPTION_KEYS.inspect} keys). Pass a flat " \
           "ClientOptions-style hash or a Supabase::ClientOptions instance to use them."
    end

    # Single internal path shared by the public `#set_auth` and the
    # `on_auth_state_change` listener installed on `#auth`. Refreshes the
    # Authorization header used by every non-auth sub-client and resets their
    # memoized instances so they pick up the new token on next access.
    # `@auth` is intentionally preserved — clearing it would also discard the
    # in-memory persisted session held by its storage backend.
    #
    # Under `async: true` the realtime fan-out is dispatched as a child
    # `Async` task so the calling fiber returns immediately instead of
    # waiting for every joined channel's `Socket#send` to drain — see
    # spec/async/apply_auth_non_blocking_spec.rb (US-047 / US-048).
    def apply_auth(token)
      @access_token = token || @supabase_key
      @headers["Authorization"] = "Bearer #{@access_token}"
      @storage = @functions = @postgrest = nil
      dispatch_realtime { @realtime&.set_auth(token) }
    end

    # Shared dispatch for every umbrella → realtime call that may touch the
    # socket (`set_auth` fan-out, `remove_channel`, `remove_all_channels`).
    # The realtime client is thread-based, so its socket writes are plain
    # blocking Ruby. Sync mode calls straight through. Under `async: true`
    # the block runs in a child `Async` task: inside a reactor the calling
    # fiber gets the task back immediately (`.wait` restores Python's `await`
    # semantics); outside a reactor `Async { }` degrades to running inline,
    # which matches the sync path.
    def dispatch_realtime(&block)
      return yield unless @async

      require "async" unless defined?(Async)
      Async(&block)
    end

    def auth_class
      @async ? require_async_class("auth", "Async::Client") : Auth::Client
    end

    def postgrest_class
      @async ? require_async_class("postgrest", "Async::Client") : Postgrest::Client
    end

    def storage_class
      @async ? require_async_class("storage", "Async::Client") : Storage::Client
    end

    def functions_class
      @async ? require_async_class("functions", "Async::Client") : Functions::Client
    end

    # Loads e.g. "supabase/postgrest/async" only when async: true so sync users
    # never pull in async-http-faraday.
    def require_async_class(sub, class_name)
      require "supabase/#{sub}/async"
      mod = const_get_from_string("Supabase::#{sub.capitalize}::#{class_name}")
      mod
    end

    def const_get_from_string(path)
      path.split("::").reduce(Object) { |m, name| m.const_get(name) }
    end

    def rest_url_for(suffix)
      "#{@supabase_url}/#{suffix}"
    end

    # Realtime uses wss:// against the project host. The realtime path is /realtime/v1.
    def realtime_url
      uri = URI.parse(@supabase_url)
      scheme = uri.scheme == "https" ? "wss" : "ws"
      port = uri.port && uri.port != uri.default_port ? ":#{uri.port}" : ""
      "#{scheme}://#{uri.host}#{port}/realtime/v1"
    end

    def sub_options(key)
      return options_from_struct(key) if @options.is_a?(Supabase::ClientOptions)

      (@options[key] || @options[key.to_s] || {}).transform_keys(&:to_sym)
    end

    # Translate a ClientOptions struct into the per-sub kwargs each sub-client
    # accepts. We don't try to surface every field — only the ones the existing
    # sub-clients actually take today.
    def options_from_struct(key)
      o = @options
      case key
      when :auth
        { auto_refresh_token: o.auto_refresh_token, persist_session: o.persist_session,
          storage: o.storage, flow_type: o.flow_type, http_client: o.http_client }.compact
      when :postgrest
        { schema: o.schema, timeout: o.postgrest_client_timeout, http_client: o.http_client }.compact
      when :storage
        { timeout: o.storage_client_timeout, http_client: o.http_client }.compact
      when :functions
        { timeout: o.function_client_timeout, http_client: o.http_client }.compact
      when :realtime
        o.realtime.is_a?(Hash) ? o.realtime.transform_keys(&:to_sym) : {}
      else
        {}
      end
    end
  end

  # Factory that matches supabase-py's `supabase.create_client()` signature.
  # Routes through `Client.create` so a persisted session in the auth client's
  # storage is restored at construction time and its access_token becomes the
  # initial Authorization bearer — instead of the anon key. See F-C6 / US-021.
  def self.create_client(supabase_url:, supabase_key:, options: {}, async: false)
    Client.create(supabase_url: supabase_url, supabase_key: supabase_key, options: options, async: async)
  end
end
