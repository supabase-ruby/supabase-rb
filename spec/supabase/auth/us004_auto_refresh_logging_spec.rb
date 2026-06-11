# frozen_string_literal: true

require "spec_helper"
require "logger"
require "stringio"

# US-004 — Auth auto-refresh contract:
#   1. Любая ошибка refresh логируется (класс + сообщение).
#   2. AuthRetryableError → реншедулинг с бэкоффом (поведение паритета с py).
#   3. Не-retryable ошибка → ОДНА запись в логе, без бесконечного цикла
#      и без перепланировки таймера.
#
# Параритетная py-ссылка: `gotrue_client.py:1105-1129` (auto refresh loop)
# и `gotrue_client.py:1036-1069` (_recover_and_refresh). Py молча глотает
# любую ошибку — rb здесь явно строже: логируем через injected logger
# либо fallback на Kernel#warn ($stderr). Согласовано с US-002 / US-003.
RSpec.describe "Supabase::Auth::Client auto-refresh error logging (US-004)" do
  let(:base_url) { "http://localhost:9999" }
  let(:log_io) { StringIO.new }
  let(:logger) { Logger.new(log_io) }

  let(:user) do
    Supabase::Auth::Types::User.new(
      id: "u-1",
      app_metadata: {},
      user_metadata: {},
      aud: "authenticated",
      email: "test@example.com",
      phone: "",
      created_at: Time.parse("2024-01-01T00:00:00Z"),
      confirmed_at: Time.parse("2024-01-01T00:00:00Z"),
      last_sign_in_at: Time.parse("2024-01-01T00:00:00Z"),
      role: "authenticated",
      updated_at: Time.parse("2024-01-01T00:00:00Z")
    )
  end

  let(:active_session) do
    Supabase::Auth::Types::Session.new(
      access_token: "access-1",
      refresh_token: "refresh-1",
      expires_in: 3600,
      expires_at: Time.now.to_i + 3600,
      token_type: "bearer",
      user: user
    )
  end

  def build_client(opts = {})
    Supabase::Auth::Client.new(
      url: base_url,
      auto_refresh_token: true,
      persist_session: false,
      logger: logger,
      **opts
    )
  end

  describe "AC #1, #2, #4 — retryable error: log + reschedule (network timeout)" do
    it "logs each AuthRetryableError with class + message and reschedules the timer" do
      client = build_client
      client.instance_variable_set(:@current_session, active_session)

      # Имитируем сетевой таймаут: AuthRetryableError — ровно то, во что
      # `Helpers.handle_exception` маппит `Faraday::TimeoutError`
      # (см. `helpers.rb` строка 105-107).
      call_count = 0
      allow(client).to receive(:_refresh_access_token) do
        call_count += 1
        raise Supabase::Auth::Errors::AuthRetryableError.new(
          "execution expired",
          status: 0
        )
      end

      reschedule_count = 0
      original_start = Supabase::Auth::Client.instance_method(:_start_auto_refresh_token)
      allow(client).to receive(:_start_auto_refresh_token).and_wrap_original do |_method, *args|
        reschedule_count += 1
        original_start.bind(client).call(*args)
      end

      # Pump первого таймера, ждём пока retry-цикл успеет завершиться
      # (короткий backoff → быстрая re-fire). До 1 секунды на 3 итерации.
      client.send(:_start_auto_refresh_token, 1)
      deadline = Time.now + 1.0
      sleep 0.02 while call_count < 2 && Time.now < deadline

      expect(call_count).to be >= 2
      # Изначальный вызов + хотя бы один reschedule из rescue-ветки.
      expect(reschedule_count).to be >= 2

      log_io.rewind
      contents = log_io.read
      expect(contents).to include("[Supabase::Auth] refresh failed in auto_refresh")
      expect(contents).to include("Supabase::Auth::Errors::AuthRetryableError")
      expect(contents).to include("execution expired")
    end

    it "_recover_and_refresh logs AuthRetryableError and schedules a retry timer" do
      client = build_client

      storage = client.instance_variable_get(:@storage)
      storage_key = client.instance_variable_get(:@storage_key)
      storage.set_item(storage_key, JSON.generate(
        "access_token" => "expired-token",
        "refresh_token" => "expired-refresh",
        "expires_in" => 1,
        "expires_at" => Time.now.to_i - 1,
        "token_type" => "bearer",
        "user" => {
          "id" => user.id, "app_metadata" => {}, "user_metadata" => {},
          "aud" => user.aud, "email" => user.email,
          "created_at" => "2024-01-01T00:00:00Z", "updated_at" => "2024-01-01T00:00:00Z"
        }
      ))

      allow(client).to receive(:_call_refresh_token).and_raise(
        Supabase::Auth::Errors::AuthRetryableError.new("Service Unavailable", status: 503)
      )

      timer_created = false
      allow(Supabase::Auth::Timer).to receive(:new).and_wrap_original do |method, *args, &block|
        timer_created = true
        timer = method.call(*args, &block)
        allow(timer).to receive(:start)
        timer
      end

      client.send(:_recover_and_refresh)

      expect(timer_created).to be true
      log_io.rewind
      contents = log_io.read
      expect(contents).to include("[Supabase::Auth] refresh failed in recover_and_refresh")
      expect(contents).to include("Supabase::Auth::Errors::AuthRetryableError")
      expect(contents).to include("Service Unavailable")
    end
  end

  describe "AC #3, #5 — non-retryable error: one log, NO reschedule" do
    it "_start_auto_refresh_token logs once and does not reschedule on AuthApiError" do
      client = build_client
      client.instance_variable_set(:@current_session, active_session)

      call_count = 0
      allow(client).to receive(:_refresh_access_token) do
        call_count += 1
        raise Supabase::Auth::Errors::AuthApiError.new("Bad Request", status: 400)
      end

      # Считаем именно reschedule (повторный вызов _start_auto_refresh_token)
      # ИЗНУТРИ rescue-ветки. Первый вызов делает тест; всё, что свыше — это
      # перепланировка из таймера. На non-retryable должно быть НОЛЬ.
      reschedule_count = 0
      original_start = Supabase::Auth::Client.instance_method(:_start_auto_refresh_token)
      allow(client).to receive(:_start_auto_refresh_token).and_wrap_original do |_method, *args|
        reschedule_count += 1
        original_start.bind(client).call(*args)
      end

      client.send(:_start_auto_refresh_token, 1)

      # Ждём пока первый таймер дойдёт до rescue-ветки.
      deadline = Time.now + 0.5
      sleep 0.02 while call_count == 0 && Time.now < deadline
      # Дополнительно даём грейс-окно, чтобы убедиться, что
      # повторного call_count не будет (=отсутствие реншедулинга).
      sleep 0.15

      expect(call_count).to eq(1)
      # Один вызов _start_auto_refresh_token от теста, никаких новых из rescue.
      expect(reschedule_count).to eq(1)

      log_io.rewind
      lines = log_io.read.lines.select { |l| l.include?("[Supabase::Auth] refresh failed") }
      expect(lines.size).to eq(1)
      expect(lines.first).to include("Supabase::Auth::Errors::AuthApiError")
      expect(lines.first).to include("Bad Request")
    end

    it "_recover_and_refresh logs once and does NOT create a retry timer on AuthApiError" do
      client = build_client

      storage = client.instance_variable_get(:@storage)
      storage_key = client.instance_variable_get(:@storage_key)
      storage.set_item(storage_key, JSON.generate(
        "access_token" => "expired-token",
        "refresh_token" => "expired-refresh",
        "expires_in" => 1,
        "expires_at" => Time.now.to_i - 1,
        "token_type" => "bearer",
        "user" => {
          "id" => user.id, "app_metadata" => {}, "user_metadata" => {},
          "aud" => user.aud, "email" => user.email,
          "created_at" => "2024-01-01T00:00:00Z", "updated_at" => "2024-01-01T00:00:00Z"
        }
      ))

      allow(client).to receive(:_call_refresh_token).and_raise(
        Supabase::Auth::Errors::AuthApiError.new("invalid_grant", status: 400)
      )

      timer_created = false
      allow(Supabase::Auth::Timer).to receive(:new).and_wrap_original do |method, *args, &block|
        timer_created = true
        timer = method.call(*args, &block)
        allow(timer).to receive(:start)
        timer
      end

      client.send(:_recover_and_refresh)

      # На non-retryable таймер не создаётся, сессия очищается.
      expect(timer_created).to be false

      log_io.rewind
      lines = log_io.read.lines.select { |l| l.include?("[Supabase::Auth] refresh failed") }
      expect(lines.size).to eq(1)
      expect(lines.first).to include("recover_and_refresh")
      expect(lines.first).to include("Supabase::Auth::Errors::AuthApiError")
      expect(lines.first).to include("invalid_grant")
    end
  end

  describe "fallback when no logger is injected" do
    it "falls back to Kernel#warn ($stderr) for refresh errors" do
      client = Supabase::Auth::Client.new(
        url: base_url,
        auto_refresh_token: true,
        persist_session: false
        # logger: omitted
      )
      err = Supabase::Auth::Errors::AuthRetryableError.new("boom", status: 0)
      expect { client.send(:_log_refresh_error, "auto_refresh", err) }
        .to output(/\[Supabase::Auth\] refresh failed in auto_refresh.*AuthRetryableError.*boom/).to_stderr
    end
  end
end
