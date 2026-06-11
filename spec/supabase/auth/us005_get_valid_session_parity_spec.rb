# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"
require "json"

# US-005: Auth — паритет `_get_valid_session` по обязательным полям.
#
# Q1 (PRD §8 — Open Questions): ослаблять ли валидацию сессии до паритета с
# py (только `expires_at`), или сохранять строгую проверку и логировать отказ?
#
# Решение: ОСЛАБИТЬ до py-parity (дефолт-предложение PRD).
#
# Эталон: supabase-py `gotrue_client.py:_get_valid_session` —
#   ```python
#   if not raw_session:
#       return None
#   try:
#       session = model_validate(Session, raw_session)
#       if session.expires_at is None:
#           return None
#       return session
#   except Exception:
#       return None
#   ```
# То есть единственная явная проверка после парсинга — `expires_at is not None`.
# Защита от "битых" данных (nil access_token / refresh_token / user) перенесена
# на этап использования сессии: `_call_refresh_token` бросает
# `AuthSessionMissing` для пустого refresh_token, `_request(jwt: nil)` уходит
# без Authorization-хедера, а `Types::Session.from_hash` спокойно принимает
# `user: nil` через `User.from_hash(nil) → nil`.
RSpec.describe "US-005: _get_valid_session parity with supabase-py" do
  let(:url) { "http://localhost:9998" }
  let(:future_ts) { Time.now.to_i + 3600 }
  let(:past_ts) { Time.now.to_i - 3600 }

  def build_client(persist_session: true, storage: nil)
    Supabase::Auth::Client.new(
      url: url,
      headers: { "X-Test" => "1" },
      persist_session: persist_session,
      storage: storage || Supabase::Auth::MemoryStorage.new,
      auto_refresh_token: false
    )
  end

  after { WebMock.reset! }

  # ---------------------------------------------------------------
  # AC-1 (Q1 decision): «Решение по Q1 зафиксировано в комментарии к PR.»
  # Этот describe-блок служит исполняемым доказательством зафиксированного
  # решения: вызовы, на которых старая строгая проверка вернула бы nil,
  # после US-005 возвращают валидную Session.
  # ---------------------------------------------------------------
  describe "Q1: parity decision is locked in by these specs" do
    it "documents the Q1 decision as a checkable contract" do
      client = build_client(persist_session: false)

      # `_get_valid_session` теперь mirrors py:
      #   * принимает raw_session,
      #   * парсит JSON / принимает Hash,
      #   * проверяет ТОЛЬКО `expires_at` (наличие + integer-парсинг),
      #   * любая прочая поломка → nil (try/except).
      raw = JSON.generate(
        "access_token" => "at",
        "refresh_token" => "rt",
        "expires_at" => future_ts
      )
      expect(client.send(:_get_valid_session, raw)).to be_a(Supabase::Auth::Types::Session)
    end
  end

  # ---------------------------------------------------------------
  # AC-2 (parity path): «проверка ослаблена до `expires_at`; защита от битых
  # данных — на этапе использования сессии; спека: сессия без `user` в storage
  # восстанавливается так же, как в py.»
  # ---------------------------------------------------------------
  describe "parity contract" do
    it "rejects session payloads with missing expires_at" do
      client = build_client(persist_session: false)
      raw = JSON.generate("access_token" => "at", "refresh_token" => "rt")
      expect(client.send(:_get_valid_session, raw)).to be_nil
    end

    it "rejects session payloads with non-integer-coercible expires_at" do
      client = build_client(persist_session: false)
      raw = JSON.generate(
        "access_token" => "at",
        "refresh_token" => "rt",
        "expires_at" => "not-a-number"
      )
      expect(client.send(:_get_valid_session, raw)).to be_nil
    end

    it "coerces string expires_at into Integer (py: pydantic-coerces int)" do
      client = build_client(persist_session: false)
      raw = JSON.generate(
        "access_token" => "at",
        "refresh_token" => "rt",
        "expires_at" => "1700000000"
      )
      session = client.send(:_get_valid_session, raw)
      expect(session.expires_at).to eq(1_700_000_000)
    end

    it "accepts session payloads without user (py: pydantic would reject, but py's gate is only expires_at)" do
      client = build_client(persist_session: false)
      raw = JSON.generate(
        "access_token" => "at",
        "refresh_token" => "rt",
        "expires_at" => future_ts
      )
      session = client.send(:_get_valid_session, raw)
      expect(session).to be_a(Supabase::Auth::Types::Session)
      expect(session.user).to be_nil
    end

    it "accepts session payloads without access_token / refresh_token" do
      client = build_client(persist_session: false)
      raw = JSON.generate("expires_at" => future_ts)
      session = client.send(:_get_valid_session, raw)
      expect(session).to be_a(Supabase::Auth::Types::Session)
      expect(session.access_token).to be_nil
      expect(session.refresh_token).to be_nil
    end

    it "returns nil for empty string raw payload (JSON.parse raises → rescued)" do
      client = build_client(persist_session: false)
      expect(client.send(:_get_valid_session, "")).to be_nil
    end

    it "returns nil for nil raw payload (matches py: `if not raw_session: return None`)" do
      client = build_client(persist_session: false)
      expect(client.send(:_get_valid_session, nil)).to be_nil
    end
  end

  # ---------------------------------------------------------------
  # AC-2 (continued): «сессия без `user` в storage восстанавливается так же,
  # как в py.» Лучшее место зафиксировать этот end-to-end путь — через
  # `_recover_and_refresh`, который читает из storage и эмитит SIGNED_IN.
  # ---------------------------------------------------------------
  describe "recover_and_refresh: session without user is restored" do
    it "restores a future-dated session that lacks the user field and emits SIGNED_IN" do
      storage = Supabase::Auth::MemoryStorage.new
      storage.set_item(
        Supabase::Auth::Client::STORAGE_KEY,
        JSON.generate(
          "access_token" => "at",
          "refresh_token" => "rt",
          "expires_at" => future_ts,
          "expires_in" => 3600,
          "token_type" => "bearer"
        )
      )

      client = build_client(storage: storage)
      events = []
      client.on_auth_state_change { |event, session| events << [event, session] }

      client.send(:_recover_and_refresh)

      restored = client.instance_variable_get(:@current_session)
      expect(restored).to be_a(Supabase::Auth::Types::Session)
      expect(restored.access_token).to eq("at")
      expect(restored.user).to be_nil

      expect(events.map(&:first)).to include("SIGNED_IN")
      signed_in = events.find { |(event, _)| event == "SIGNED_IN" }
      expect(signed_in[1].user).to be_nil
    end
  end

  # ---------------------------------------------------------------
  # «защита от битых данных — на этапе использования сессии».
  # Подтверждаем, что user-facing методы либо корректно работают на
  # session с nil-полями, либо бросают понятную доменную ошибку — но
  # никогда не падают с NoMethodError на nil.
  # ---------------------------------------------------------------
  describe "use-site defence after a relaxed restore" do
    it "_call_refresh_token raises AuthSessionMissing for an empty refresh token (py-parity guard)" do
      client = build_client(persist_session: false)

      expect {
        client.send(:_call_refresh_token, nil)
      }.to raise_error(Supabase::Auth::Errors::AuthSessionMissing)

      expect {
        client.send(:_call_refresh_token, "")
      }.to raise_error(Supabase::Auth::Errors::AuthSessionMissing)
    end

    it "refresh_session raises AuthSessionMissing when the restored session has no refresh_token" do
      client = build_client(persist_session: false)
      relaxed_session = Supabase::Auth::Types::Session.new(
        access_token: nil,
        refresh_token: nil,
        token_type: nil,
        expires_in: nil,
        expires_at: future_ts,
        user: nil
      )
      client.instance_variable_set(:@current_session, relaxed_session)

      expect {
        client.refresh_session
      }.to raise_error(Supabase::Auth::Errors::AuthSessionMissing)
    end
  end
end
