# frozen_string_literal: true

require "faraday"

# Helpers for asserting the exact query string Faraday emits for a PostgREST
# builder. We intercept at the Faraday connection level (test adapter) and
# preserve the params_encoder configured by Client#build_session, so the
# assertion fails if FlatParamsEncoder isn't wired up.
module PostgrestQueryHelper
  def expect_query(builder, expected_string)
    request = builder.request
    real_session = request.session
    method = request.http_method.downcase.to_sym
    captured = nil

    test_session = Faraday.new(url: real_session.url_prefix.to_s) do |f|
      f.options.params_encoder = real_session.options.params_encoder
      f.adapter :test do |stub|
        stub.send(method, request.path) do |env|
          captured = env.url.query.to_s
          [200, { "Content-Type" => "application/json" }, "[]"]
        end
      end
    end

    request.session = test_session
    builder.execute

    expect(captured).to eq(expected_string)
  end
end

RSpec.configure do |config|
  config.include PostgrestQueryHelper
end
