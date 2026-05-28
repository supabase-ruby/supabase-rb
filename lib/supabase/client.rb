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

    def initialize(supabase_url:, supabase_key:, options: {}, async: false)
      raise ArgumentError, "supabase_url is required"  if supabase_url.to_s.empty?
      raise ArgumentError, "supabase_key is required"  if supabase_key.to_s.empty?

      @supabase_url = supabase_url.to_s.chomp("/")
      @supabase_key = supabase_key
      @options      = options || {}
      @async        = async

      @headers = {
        "apikey"        => @supabase_key,
        "Authorization" => "Bearer #{@supabase_key}"
      }.merge(@options[:global]&.dig(:headers) || @options.dig("global", "headers") || {})
    end

    def async?
      @async
    end

    # --- Sub-clients ---------------------------------------------------------

    def auth
      @auth ||= auth_class.new(url: rest_url_for("auth/v1"), headers: @headers, **sub_options(:auth))
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
      @realtime ||= Realtime::Client.new(
        url:    realtime_url,
        params: { "apikey" => @supabase_key, "access_token" => @supabase_key },
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

    def rpc(func, params = {}, **opts)
      postgrest.rpc(func, params, **opts)
    end

    def schema(name)
      @postgrest = postgrest.schema(name)
      self
    end

    # --- Shared auth context -------------------------------------------------

    # Update the Authorization header used by every sub-client. Useful after
    # auth.sign_in returns a fresh JWT — the apikey stays the same but the
    # bearer token becomes the user's access token.
    def set_auth(token)
      @headers["Authorization"] = "Bearer #{token || @supabase_key}"
      # Reset memoized sub-clients so they pick up the new header on next access.
      # Realtime gets its own pathway (set_auth pushes access_token frames).
      @auth      = nil
      @storage   = nil
      @functions = nil
      @postgrest = nil
      @realtime&.set_auth(token)
      self
    end

    private

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
      (@options[key] || @options[key.to_s] || {}).transform_keys(&:to_sym)
    end
  end

  # Factory that matches supabase-py's `supabase.create_client()` signature.
  def self.create_client(supabase_url:, supabase_key:, options: {}, async: false)
    Client.new(supabase_url: supabase_url, supabase_key: supabase_key, options: options, async: async)
  end
end
