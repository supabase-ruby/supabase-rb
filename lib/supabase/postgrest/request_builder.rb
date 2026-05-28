# frozen_string_literal: true

require "json"
require "faraday"

require_relative "errors"
require_relative "types"
require_relative "utils"

module Supabase
  module Postgrest
    # Internal: groups method, query params, headers, and JSON body for one PostgREST request.
    class RequestConfig
      MAX_RETRIES = 3

      attr_accessor :session, :path, :http_method, :headers, :params, :json, :retry_enabled

      # @param session [Faraday::Connection]
      def initialize(session:, path:, http_method:, headers: {}, params: {}, json: nil, retry_enabled: true)
        @session = session
        @path = path
        @http_method = http_method.to_s.upcase
        @headers = headers || {}
        @params = params || {}
        @json = %w[GET HEAD].include?(@http_method) ? nil : json
        @retry_enabled = retry_enabled
      end

      def send_request(additional_headers = {})
        merged_headers = @headers.merge(additional_headers)
        body = @json ? JSON.generate(@json) : nil

        @session.run_request(@http_method.downcase.to_sym, @path, body, merged_headers) do |req|
          req.params.update(@params) unless @params.empty?
          req.headers["Content-Type"] ||= "application/json" if body
        end
      end

      def should_retry?(response, attempt_count)
        return false unless @retry_enabled
        return false if attempt_count >= MAX_RETRIES
        return false unless %w[GET HEAD].include?(@http_method)

        [503, 520].include?(response.status)
      end
    end

    # Internal: prepares default headers + params + method for the four CRUD verbs.
    module RequestPrep
      module_function

      def unique_columns(rows)
        keys = rows.each_with_object([]) do |row, acc|
          row.each_key { |k| acc << k unless acc.include?(k) }
        end
        keys.map { |k| %("#{k}") }.join(",")
      end

      def cleaned_columns(columns)
        quoted = false
        columns.map do |column|
          column.to_s.each_char.each_with_object(+"") do |char, out|
            if char =~ /\s/ && !quoted
              next
            end
            quoted = !quoted if char == '"'
            out << char
          end
        end.join(",")
      end

      def pre_select(*columns, count: nil, head: nil)
        method = head ? Types::RequestMethod::HEAD : Types::RequestMethod::GET
        cleaned = cleaned_columns(columns.empty? ? %w[*] : columns)
        params = { "select" => cleaned }
        headers = count ? { "Prefer" => "count=#{count}" } : {}
        [method, params, headers, {}]
      end

      def pre_insert(json, count:, returning:, upsert:, default_to_null: true)
        prefer = ["return=#{returning}"]
        prefer << "count=#{count}" if count
        prefer << "resolution=merge-duplicates" if upsert
        prefer << "missing=default" unless default_to_null

        headers = { "Prefer" => prefer.join(",") }
        params = {}
        params["columns"] = unique_columns(json) if json.is_a?(Array) && !json.empty?
        [Types::RequestMethod::POST, params, headers, json]
      end

      def pre_upsert(json, count:, returning:, ignore_duplicates:, on_conflict: "", default_to_null: true)
        prefer = ["return=#{returning}"]
        prefer << "count=#{count}" if count
        resolution = ignore_duplicates ? "ignore" : "merge"
        prefer << "resolution=#{resolution}-duplicates"
        prefer << "missing=default" unless default_to_null

        headers = { "Prefer" => prefer.join(",") }
        params = {}
        params["on_conflict"] = on_conflict if on_conflict && !on_conflict.empty?
        params["columns"] = unique_columns(json) if json.is_a?(Array) && !json.empty?
        [Types::RequestMethod::POST, params, headers, json]
      end

      def pre_update(json, count:, returning:)
        prefer = ["return=#{returning}"]
        prefer << "count=#{count}" if count
        [Types::RequestMethod::PATCH, {}, { "Prefer" => prefer.join(",") }, json]
      end

      def pre_delete(count:, returning:)
        prefer = ["return=#{returning}"]
        prefer << "count=#{count}" if count
        [Types::RequestMethod::DELETE, {}, { "Prefer" => prefer.join(",") }, {}]
      end
    end

    # Result of {QueryRequestBuilder#execute}. `data` is an Array of rows (or whatever
    # PostgREST returned). `count` is populated when the request used a count Prefer header.
    class APIResponse
      attr_reader :data, :count

      def initialize(data:, count: nil)
        @data = data
        @count = count
      end

      def self.from_response(response, request_prefer: nil)
        count = extract_count(response, request_prefer)
        data =
          begin
            body = response.body
            body && !body.empty? ? JSON.parse(body) : []
          rescue JSON::ParserError
            body.to_s.empty? ? [] : body.to_s
          end
        new(data: data, count: count)
      end

      def self.extract_count(response, request_prefer)
        return nil unless request_prefer
        return nil unless request_prefer.match?(/count=(?:exact|planned|estimated)/)

        content_range = response.headers["content-range"] || response.headers["Content-Range"]
        return nil unless content_range

        total = content_range.split("/").last
        total == "*" ? nil : total.to_i
      end
    end

    # Same as APIResponse but the wire was scalar (single-row endpoints).
    class SingleAPIResponse < APIResponse
      def self.from_response(response, request_prefer: nil)
        count = APIResponse.extract_count(response, request_prefer)
        data =
          begin
            body = response.body
            body && !body.empty? ? JSON.parse(body) : []
          rescue JSON::ParserError
            body.to_s.empty? ? [] : body.to_s
          end
        new(data: data, count: count)
      end
    end

    # Internal: shared execute helper (retry loop + error mapping).
    module RequestExec
      module_function

      def send_with_retry(request)
        attempt = 0
        loop do
          extra = attempt.positive? ? { "X-Retry-Count" => attempt.to_s } : {}
          response = request.send_request(extra)
          return response if (200..299).include?(response.status)
          return response unless request.should_retry?(response, attempt)

          sleep(retry_delay(attempt))
          attempt += 1
        end
      end

      def retry_delay(attempt)
        [2**attempt, 30].min
      end

      def parse_error(response)
        body = response.body
        parsed =
          begin
            body && !body.empty? ? JSON.parse(body) : nil
          rescue JSON::ParserError
            nil
          end

        Errors::APIError.new(parsed || Errors.generate_default_error_message(response))
      end
    end

    # Mixin providing PostgREST filter operators (eq, neq, gt, lt, like, in_, contains, …).
    # Methods return self so they're chainable. Mirrors supabase-py's BaseFilterRequestBuilder.
    module FilterMixin
      def not_
        @negate_next = true
        self
      end

      def filter(column, operator, criteria)
        if @negate_next
          @negate_next = false
          operator = "#{Types::Filters::NOT}.#{operator}"
        end
        key = Utils.sanitize_param(column)
        val = "#{operator}.#{criteria}"
        @request.params = add_param(@request.params, key, val)
        self
      end

      def eq(column, value); filter(column, Types::Filters::EQ, value); end
      def neq(column, value); filter(column, Types::Filters::NEQ, value); end
      def gt(column, value); filter(column, Types::Filters::GT, value); end
      def gte(column, value); filter(column, Types::Filters::GTE, value); end
      def lt(column, value); filter(column, Types::Filters::LT, value); end
      def lte(column, value); filter(column, Types::Filters::LTE, value); end

      def is_(column, value)
        v = value.nil? ? "null" : value
        filter(column, Types::Filters::IS, v)
      end

      def like(column, pattern); filter(column, Types::Filters::LIKE, pattern); end
      def ilike(column, pattern); filter(column, Types::Filters::ILIKE, pattern); end

      def like_all_of(column, pattern); filter(column, Types::Filters::LIKE_ALL, "{#{pattern}}"); end
      def like_any_of(column, pattern); filter(column, Types::Filters::LIKE_ANY, "{#{pattern}}"); end
      def ilike_all_of(column, pattern); filter(column, Types::Filters::ILIKE_ALL, "{#{pattern}}"); end
      def ilike_any_of(column, pattern); filter(column, Types::Filters::ILIKE_ANY, "{#{pattern}}"); end

      def fts(column, query); filter(column, Types::Filters::FTS, query); end
      def plfts(column, query); filter(column, Types::Filters::PLFTS, query); end
      def phfts(column, query); filter(column, Types::Filters::PHFTS, query); end
      def wfts(column, query); filter(column, Types::Filters::WFTS, query); end

      def in_(column, values)
        sanitized = values.map { |v| Utils.sanitize_param(v) }.join(",")
        filter(column, Types::Filters::IN, "(#{sanitized})")
      end

      def cs(column, values)
        joined = values.is_a?(Array) ? values.join(",") : values.to_s
        filter(column, Types::Filters::CS, "{#{joined}}")
      end

      def cd(column, values)
        joined = values.is_a?(Array) ? values.join(",") : values.to_s
        filter(column, Types::Filters::CD, "{#{joined}}")
      end

      def contains(column, value)
        case value
        when String
          filter(column, Types::Filters::CS, value)
        when Hash
          filter(column, Types::Filters::CS, JSON.generate(value))
        when Enumerable
          filter(column, Types::Filters::CS, "{#{value.to_a.join(',')}}")
        else
          filter(column, Types::Filters::CS, JSON.generate(value))
        end
      end

      def contained_by(column, value)
        case value
        when String
          filter(column, Types::Filters::CD, value)
        when Hash
          filter(column, Types::Filters::CD, JSON.generate(value))
        when Enumerable
          filter(column, Types::Filters::CD, "{#{value.to_a.join(',')}}")
        else
          filter(column, Types::Filters::CD, JSON.generate(value))
        end
      end

      def ov(column, value)
        case value
        when String
          filter(column, Types::Filters::OV, value)
        when Hash
          filter(column, Types::Filters::OV, JSON.generate(value))
        when Enumerable
          filter(column, Types::Filters::OV, "{#{value.to_a.join(',')}}")
        else
          filter(column, Types::Filters::OV, JSON.generate(value))
        end
      end

      def sl(column, range); filter(column, Types::Filters::SL, "(#{range[0]},#{range[1]})"); end
      def sr(column, range); filter(column, Types::Filters::SR, "(#{range[0]},#{range[1]})"); end
      def nxl(column, range); filter(column, Types::Filters::NXL, "(#{range[0]},#{range[1]})"); end
      def nxr(column, range); filter(column, Types::Filters::NXR, "(#{range[0]},#{range[1]})"); end
      def adj(column, range); filter(column, Types::Filters::ADJ, "(#{range[0]},#{range[1]})"); end

      def range_lt(column, range); sl(column, range); end
      def range_gt(column, range); sr(column, range); end
      def range_gte(column, range); nxl(column, range); end
      def range_lte(column, range); nxr(column, range); end
      def range_adjacent(column, range); adj(column, range); end
      def overlaps(column, values); ov(column, values); end

      def match(query)
        raise ArgumentError, "query must contain at least one key-value pair" if query.nil? || query.empty?

        result = self
        query.each { |k, v| result = eq(k, v) }
        result
      end

      def or_(filters, reference_table: nil)
        key = reference_table ? "#{Utils.sanitize_param(reference_table)}.or" : "or"
        @request.params = add_param(@request.params, key, "(#{filters})")
        self
      end

      def max_affected(value)
        existing = @request.headers["Prefer"] || ""
        prefer = existing.dup
        unless prefer.empty?
          prefer += ",handling=strict" unless prefer.include?("handling=strict")
        end
        prefer = "handling=strict" if prefer.empty?
        prefer += ",max-affected=#{value}"
        @request.headers["Prefer"] = prefer
        self
      end

      private

      # PostgREST allows the same query key to appear multiple times (e.g. multiple
      # `order=` or repeated filter columns). Ruby Hash collapses by key, so we
      # store repeats as Arrays — Faraday emits them as multiple query params.
      def add_param(params, key, value)
        existing = params[key]
        params[key] = if existing.is_a?(Array)
                        existing + [value]
                      elsif existing
                        [existing, value]
                      else
                        value
                      end
        params
      end
    end

    # Mixin providing select-only modifiers (order/limit/offset/range).
    module SelectMixin
      def order(column, desc: false, nullsfirst: nil, foreign_table: nil)
        key = foreign_table ? "#{foreign_table}.order" : "order"
        direction = desc ? "desc" : "asc"
        nulls = nullsfirst.nil? ? "" : ".#{nullsfirst ? 'nullsfirst' : 'nullslast'}"
        new_value = "#{column}.#{direction}#{nulls}"

        existing = @request.params[key]
        @request.params[key] = existing ? "#{existing},#{new_value}" : new_value
        self
      end

      def limit(size, foreign_table: nil)
        key = foreign_table ? "#{foreign_table}.limit" : "limit"
        @request.params[key] = size
        self
      end

      def offset(size)
        @request.params["offset"] = size
        self
      end

      def range(start, finish, foreign_table: nil)
        offset_key = foreign_table ? "#{foreign_table}.offset" : "offset"
        limit_key = foreign_table ? "#{foreign_table}.limit" : "limit"
        @request.params[offset_key] = start
        @request.params[limit_key] = finish - start + 1
        self
      end
    end

    # Builder returned by select() / insert() / upsert() / update() / delete() — call #execute to fire.
    class QueryRequestBuilder
      attr_reader :request

      def initialize(request)
        @request = request
        @negate_next = false
      end

      def retry(enabled)
        @request.retry_enabled = enabled
        self
      end

      def select(*columns)
        _, params, _, _ = RequestPrep.pre_select(*columns, count: nil)
        @request.params["select"] = params["select"]
        prefer = @request.headers["Prefer"] || ""
        parts = prefer.split(",").reject { |h| h.start_with?("return=") }
        parts << "return=representation"
        @request.headers["Prefer"] = parts.join(",")
        self
      end

      def execute
        response = RequestExec.send_with_retry(@request)
        if (200..299).include?(response.status)
          APIResponse.from_response(response, request_prefer: @request.headers["Prefer"])
        else
          raise RequestExec.parse_error(response)
        end
      end
    end

    # Returned by select().single() and rpc().single(); raises if PostgREST doesn't return exactly one row.
    class SingleRequestBuilder
      attr_reader :request

      def initialize(request)
        @request = request
      end

      def retry(enabled)
        @request.retry_enabled = enabled
        self
      end

      def execute
        response = RequestExec.send_with_retry(@request)
        if (200..299).include?(response.status)
          SingleAPIResponse.from_response(response, request_prefer: @request.headers["Prefer"])
        else
          raise RequestExec.parse_error(response)
        end
      end
    end

    # Returned by select().maybe_single() — yields the row or nil, raises on >1 result.
    class MaybeSingleRequestBuilder
      attr_reader :request

      def initialize(request)
        @request = request
      end

      def retry(enabled)
        @request.retry_enabled = enabled
        self
      end

      def execute
        response = RequestExec.send_with_retry(@request)
        unless (200..299).include?(response.status)
          raise RequestExec.parse_error(response)
        end

        parsed = APIResponse.from_response(response, request_prefer: @request.headers["Prefer"])
        return nil if parsed.data.is_a?(Array) && parsed.data.empty?

        if parsed.data.is_a?(Array) && parsed.data.length == 1
          SingleAPIResponse.new(data: parsed.data.first, count: parsed.count)
        else
          raise Errors::APIError.new(
            "message" => "Cannot coerce the result to a single JSON object",
            "code" => "406",
            "hint" => "Please check the result set",
            "details" => "The result contains more than one row."
          )
        end
      end
    end

    # Returned by select().explain() with format: :text — body is the EXPLAIN plan text.
    class ExplainRequestBuilder
      attr_reader :request

      def initialize(request)
        @request = request
      end

      def retry(enabled)
        @request.retry_enabled = enabled
        self
      end

      def execute
        response = RequestExec.send_with_retry(@request)
        return response.body if (200..299).include?(response.status)

        raise RequestExec.parse_error(response)
      end
    end

    # The most common builder type — returned by update() and delete(), and used as
    # the base for SelectRequestBuilder. Combines QueryRequestBuilder's execute with
    # filter operators.
    class FilterRequestBuilder < QueryRequestBuilder
      include FilterMixin
    end

    # Returned by select() — filters + select modifiers + result-shape switchers.
    class SelectRequestBuilder < FilterRequestBuilder
      include SelectMixin

      def single
        @request.headers["Accept"] = "application/vnd.pgrst.object+json"
        SingleRequestBuilder.new(@request)
      end

      def maybe_single
        MaybeSingleRequestBuilder.new(@request)
      end

      def csv
        @request.headers["Accept"] = "text/csv"
        SingleRequestBuilder.new(@request)
      end

      def text_search(column, query, options = {})
        type_part = case options[:type] || options["type"]
                    when "plain" then "pl"
                    when "phrase" then "ph"
                    when "web_search" then "w"
                    else ""
                    end
        config = options[:config] || options["config"]
        config_part = config ? "(#{config})" : ""
        @request.params[column.to_s] = "#{type_part}fts#{config_part}.#{query}"
        QueryRequestBuilder.new(@request)
      end

      def explain(analyze: false, verbose: false, settings: false, buffers: false, wal: false, format: "text")
        options = []
        options << "analyze" if analyze
        options << "verbose" if verbose
        options << "settings" if settings
        options << "buffers" if buffers
        options << "wal" if wal
        @request.headers["Accept"] = "application/vnd.pgrst.plan+#{format}; options=#{options.join('|')}"
        format == "text" ? ExplainRequestBuilder.new(@request) : SingleRequestBuilder.new(@request)
      end
    end

    # Returned by rpc() — filters + select modifiers + result-shape switchers, returning
    # SingleAPIResponse instead of APIResponse because PostgREST returns a single value.
    class RPCFilterRequestBuilder < SingleRequestBuilder
      include FilterMixin
      include SelectMixin

      def initialize(request)
        super
        @negate_next = false
      end

      def select(*columns)
        _, params, _, _ = RequestPrep.pre_select(*columns, count: nil)
        existing = @request.params["select"]
        @request.params["select"] = existing ? "#{existing},#{params['select']}" : params["select"]
        prefer = @request.headers["Prefer"] || ""
        @request.headers["Prefer"] = prefer.empty? ? "return=representation" : "#{prefer},return=representation"
        self
      end

      def single
        @request.headers["Accept"] = "application/vnd.pgrst.object+json"
        self
      end

      def maybe_single
        @request.headers["Accept"] = "application/vnd.pgrst.object+json"
        self
      end

      def csv
        @request.headers["Accept"] = "text/csv"
        self
      end
    end

    # Entry point for table operations — produced by Client#from(table). Each method
    # builds an appropriate sub-builder (Select / Filter / Query) and returns it for
    # chaining.
    class RequestBuilder
      def initialize(session, path, headers)
        @session = session
        @path = path
        @headers = headers
      end

      def select(*columns, count: nil, head: nil)
        method, params, headers, json = RequestPrep.pre_select(*columns, count: count, head: head)
        request = RequestConfig.new(
          session: @session, path: @path, http_method: method,
          headers: headers.merge(@headers), params: params, json: json
        )
        SelectRequestBuilder.new(request)
      end

      def insert(json, count: nil, returning: Types::ReturnMethod::REPRESENTATION,
                 upsert: false, default_to_null: true)
        method, params, headers, body = RequestPrep.pre_insert(
          json, count: count, returning: returning, upsert: upsert, default_to_null: default_to_null
        )
        request = RequestConfig.new(
          session: @session, path: @path, http_method: method,
          headers: headers.merge(@headers), params: params, json: body
        )
        QueryRequestBuilder.new(request)
      end

      def upsert(json, count: nil, returning: Types::ReturnMethod::REPRESENTATION,
                 ignore_duplicates: false, on_conflict: "", default_to_null: true)
        method, params, headers, body = RequestPrep.pre_upsert(
          json, count: count, returning: returning,
          ignore_duplicates: ignore_duplicates, on_conflict: on_conflict,
          default_to_null: default_to_null
        )
        request = RequestConfig.new(
          session: @session, path: @path, http_method: method,
          headers: headers.merge(@headers), params: params, json: body
        )
        QueryRequestBuilder.new(request)
      end

      def update(json, count: nil, returning: Types::ReturnMethod::REPRESENTATION)
        method, params, headers, body = RequestPrep.pre_update(
          json, count: count, returning: returning
        )
        request = RequestConfig.new(
          session: @session, path: @path, http_method: method,
          headers: headers.merge(@headers), params: params, json: body
        )
        FilterRequestBuilder.new(request)
      end

      def delete(count: nil, returning: Types::ReturnMethod::REPRESENTATION)
        method, params, headers, body = RequestPrep.pre_delete(
          count: count, returning: returning
        )
        request = RequestConfig.new(
          session: @session, path: @path, http_method: method,
          headers: headers.merge(@headers), params: params, json: body
        )
        FilterRequestBuilder.new(request)
      end
    end
  end
end
