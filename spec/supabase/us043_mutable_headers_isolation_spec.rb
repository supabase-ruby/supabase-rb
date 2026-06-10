# frozen_string_literal: true

require "supabase"

# US-043 — Mutable-headers isolation.
#
# Paritetно с py `test_mutable_headers_issue` (client/supabase-py/.../tests/_sync/test_client.py:146):
# два клиента, созданных из одного `ClientOptions` объекта, не должны делить
# `options.headers` через class-instance side-effects — мутация одного хеша не
# должна утекать в другой клиент.
#
# Источник бага: до US-043 `Supabase::Client#initialize` хранил переданный
# `ClientOptions` по ссылке (`@options = options`), поэтому `client1.options`
# и `client2.options` указывали на один и тот же объект, и `options.headers`
# был общим Hash'ем. Fix: shallow `dup` опций + `dup` хэша headers.
RSpec.describe Supabase::Client, "US-043 — mutable-headers isolation" do
  let(:project_url) { "https://abc.supabase.co" }
  let(:key)         { "anon-key" }

  it "mutating client1.options.headers does not affect client2.options.headers (parity with py test_mutable_headers_issue)" do
    shared_options = Supabase::ClientOptions.new(
      headers: { "Authorization" => "Bearer initial-token" }
    )

    client1 = described_class.new(supabase_url: project_url, supabase_key: key, options: shared_options)
    client2 = described_class.new(supabase_url: project_url, supabase_key: key, options: shared_options)

    client1.options.headers["Authorization"] = "Bearer modified-token"

    expect(client2.options.headers["Authorization"]).to eq("Bearer initial-token")
    expect(client1.options.headers["Authorization"]).to eq("Bearer modified-token")
  end

  it "each client gets its own ClientOptions object (shallow dup), not the shared instance" do
    shared_options = Supabase::ClientOptions.new(headers: { "X-Tenant" => "acme" })

    client1 = described_class.new(supabase_url: project_url, supabase_key: key, options: shared_options)
    client2 = described_class.new(supabase_url: project_url, supabase_key: key, options: shared_options)

    expect(client1.options).not_to be(shared_options)
    expect(client2.options).not_to be(shared_options)
    expect(client1.options).not_to be(client2.options)
  end

  it "options.headers hashes are distinct objects between the two clients (deeper isolation guard)" do
    shared_options = Supabase::ClientOptions.new(headers: { "X-Tenant" => "acme" })

    client1 = described_class.new(supabase_url: project_url, supabase_key: key, options: shared_options)
    client2 = described_class.new(supabase_url: project_url, supabase_key: key, options: shared_options)

    expect(client1.options.headers).not_to be(client2.options.headers)
    expect(client1.options.headers).not_to be(shared_options.headers)
  end

  it "mutating shared_options.headers AFTER construction does not bleed into either client" do
    shared_options = Supabase::ClientOptions.new(
      headers: { "Authorization" => "Bearer initial-token" }
    )

    client1 = described_class.new(supabase_url: project_url, supabase_key: key, options: shared_options)
    client2 = described_class.new(supabase_url: project_url, supabase_key: key, options: shared_options)

    shared_options.headers["Authorization"] = "Bearer post-hoc-mutation"

    expect(client1.options.headers["Authorization"]).to eq("Bearer initial-token")
    expect(client2.options.headers["Authorization"]).to eq("Bearer initial-token")
  end
end
