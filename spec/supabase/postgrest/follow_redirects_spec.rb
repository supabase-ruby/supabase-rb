# frozen_string_literal: true

require "supabase/postgrest"
require "webmock/rspec"
require "json"

# C-PG-2 fix: supabase-py's httpx client uses `follow_redirects=True`. The rb
# Faraday client now wires `faraday-follow_redirects` so a 3xx from
# PostgREST / a proxy / Cloudflare is followed transparently instead of
# surfacing as an APIError.
RSpec.describe "Postgrest follows 3xx redirects" do
  let(:base) { "https://example.supabase.co/rest/v1" }

  let(:client) do
    Supabase::Postgrest::Client.new(
      base_url: base,
      headers:  { "apikey" => "anon", "Authorization" => "Bearer tok" }
    )
  end

  before { WebMock.disable_net_connect! }
  after  { WebMock.allow_net_connect! }

  it "follows a 307 redirect and returns the final body" do
    stub_request(:get, %r{\Ahttps://example\.supabase\.co/rest/v1/users(\?.*)?\z})
      .to_return(status: 307, headers: { "Location" => "https://cdn.example.com/users" })
    stub_request(:get, "https://cdn.example.com/users")
      .to_return(status: 200, body: JSON.generate([{ "id" => 1 }]),
                 headers: { "Content-Type" => "application/json" })

    res = client.from("users").select("*").execute

    expect(res.data).to eq([{ "id" => 1 }])
  end
end
