# PARITY.md — намеренные отклонения от supabase-py

supabase-rb — порт [supabase-py](https://github.com/supabase/supabase-py)
(источник истины для поведения). Этот файл фиксирует места, где Ruby-порт
**сознательно** отклоняется от Python — чтобы при будущих синках с upstream
эти отличия не были приняты за баги и «исправлены» обратно.

Правило: если поведение Ruby отличается от Python и не описано здесь — это
баг порта, заводите issue. Если описано здесь — это контракт; менять его можно
только осознанным решением с обновлением этого файла.

Формат ссылок: `python-файл:строка ↔ ruby-файл:строка` (строки на момент
ревью 2026-06-11, могут плыть).

---

## Сквозные решения

### Один класс `Client` с флагом `async:` вместо пары Sync/Async классов
- py: отдельные `Client` / `AsyncClient` (+ unasync-генерация `_sync` из `_async`).
- rb: один класс на модуль; async-вариант — наследник, подменяющий только
  Faraday-адаптер (`lib/supabase/*/async/client.rb`). Умбрелла —
  `Supabase::Client.new(..., async: true)`.
- Почему: нет дублирования кода, request-builder'ы транспорт-агностичны.

### Pydantic-модели → Struct / Hash
- Возвращаемые типы — Ruby Struct'ы (`Types::*`) или Hash вместо Pydantic
  BaseModel. Валидация типов на рантайме не воспроизводится.
- Для миграции с Python оставлены алиасы полей/методов в py-стиле
  (`from_`, `table`, `signedURL` и т.п.).

### Hash-доступ терпит и строковые, и символьные ключи
- Везде, где Python читает `dict["key"]`, Ruby читает
  `h["key"] || h[:key]`. Более защитно; не сужать при синке.

### `logger:`-инъекция
- rb добавляет опциональный `logger:` (auth, realtime) с фоллбэком на
  `Kernel.warn`. В Python аналога нет — не удалять как «лишнее».

---

## Top-level client (`lib/supabase/client.rb`)

### `remove_channel` / `remove_all_channels` под `async: true` возвращают `Async::Task` (US-050)
- py: `supabase/_async/client.py:231-237` — `async def`, вызывающий awaits.
- rb: `client.rb` → `dispatch_realtime` — в sync-режиме блокирующий вызов
  (паритет с py-sync); под `async: true` realtime-teardown уходит в дочернюю
  `Async`-таску, вызов возвращает таску, `.wait` на ней = `await` в Python.
- Почему: realtime-клиент в rb тредовый, его `Socket#send` — блокирующий;
  без диспатча файбер вызывающего висел бы на всю запись phx_leave.
  Тот же паттерн, что у `apply_auth` (US-047/US-048).
- Спеки: `spec/async/remove_channel_non_blocking_spec.rb`,
  `spec/async/apply_auth_non_blocking_spec.rb`.

### Публичный `Client#set_auth(token)`
- py: обновление токена — только через внутренний `_listen_to_auth_events`.
- rb: `set_auth` публичен — можно явно ротировать bearer без событий auth.

### Legacy-форма опций (вложенный Hash) поддерживается наряду с `ClientOptions`
- rb принимает и `ClientOptions`, и старую форму
  `{ auth: {...}, global: { headers: {...} } }` (`client.rb:80-98`).
  В py — только dataclass. Не выпиливать при синке.

### X-Client-Info короче
- py: `supabase-py/x.y.z; platform=...; ...`. rb: `supabase-rb/x.y.z`
  (`client_options.rb`). Платформенные детали намеренно не отправляются.

---

## Realtime (`lib/supabase/realtime/`)

### Потоки вместо asyncio — все публичные методы синхронные
- py: всё `async def`, пользователь `await`-ит.
- rb: блокирующие методы; heartbeat / reconnect / read-loop — фоновые треды.
  Тред-сейфти — явные мьютексы (Presence, Push, Timer, send-buffer).
- Колбэки выполняются на read-треде: долгий колбэк тормозит доставку.
  Исключения в колбэках гасятся `CallbackSafety` (US-002) и не убивают
  read-loop — в py эквивалент обеспечивает asyncio.

### Встроенный авто-reconnect + `on_reconnect_failed` (US-003)
- py: `connect()` бросает исключение при провале; ретраи — забота вызывающего
  (`_async/client.py:124-193`).
- rb: `connect` возвращает self; при падении сокета фоновый тред переподключает
  с экспоненциальным backoff (cap 60s — как в py); при исчерпании ретраев
  стреляет колбэк `on_reconnect_failed(&block)` (`realtime/client.rb:328-357`).
- Почему: rb-клиент рассчитан на долгоживущие фоновые сервисы.

### `channel.push` → `channel.push_event`
- py: публичный `channel.push(event, payload, timeout)`.
- rb: публичный `push_event(event, payload, timeout:)`; `push` приватный —
  чтобы не конфликтовать с устоявшейся семантикой `push` у коллекций и не
  затенять `Object`-протоколы.

### `subscribe` принимает блок, а не аргумент-колбэк
- py: `await channel.subscribe(callback)`.
- rb: `channel.subscribe { |state, err| ... }` (блокирующий).

### Публичные хуки `on_close` / `on_error` у канала
- В py пользовательских хуков нет (только внутренние обработчики).
  rb отдаёт их наружу (`channel.rb:157-165`). Не удалять.

### Инъекция транспорта/сокета
- rb: `transport:` / `socket:` в конструкторе и `use_socket` — подмена
  WS-реализации (websocket-client-simple / async-websocket / тестовый сокет).
  В py транспорт зашит (websockets).

### Топик-префикс `realtime:` добавляется идемпотентно
- py: префиксует безусловно (`client.py:285`) — двойной префикс возможен.
- rb: проверяет `start_with?("realtime:")` (`realtime/client.rb:151`).
  Намеренное отличие в пользу rb.

---

## Functions (`lib/supabase/functions/`)

Здесь rb в нескольких местах сознательно ведёт себя **строже/безопаснее**
источника истины. При синках с upstream не «чинить» обратно до py-поведения.

### `invoke` — kwargs вместо `invoke_options`-словаря; нет `method:`/`query:`
- py: `invoke(name, invoke_options: dict)` (`functions_client.py:124-177`).
- rb: `invoke(name, body:, headers:, region:, response_type:, return_response:)`.
  `method`/`query` не портированы — это JS-реликты, которых нет и в py (US-030).
  `return_response:` — rb-добавка для обратной совместимости обёртки (US-026).

### Content-Type пользователя уважается (`||=`, а не `=`)
- py перезаписывает пользовательский Content-Type (`functions_client.py:161-163`) —
  это баг источника. rb: `merged_headers["Content-Type"] ||= ...`
  (`functions/client.rb:101-113`). Спек: `client_di_and_content_type_spec.rb`.

### Регион валидируется до запроса
- py: коэрсит строку в enum с warning; на мусоре — необработанный `ValueError`.
- rb: `validate_region!` бросает `ArgumentError` с указанием значения до
  HTTP-вызова (`functions/client.rb:161-168`, US-029).

### Безопасный JSON-парсинг ответов
- py: `response.json()` падает `JSONDecodeError` на битом JSON (и в 2xx при
  `responseType: "json"`, и при разборе тела ошибки).
- rb: `parse_json_safe` → nil → фоллбэк на сырое тело / синтетическое сообщение
  (`functions/client.rb:180-186, 208-211`).

### `x-relay-header` проверяется без учёта регистра
- py смотрит только lowercase; rb — оба варианта (`functions/client.rb:170-178`),
  по RFC 7230.

### `response_type: :binary` (US-046)
- В py нет аналога (для не-JSON всегда возвращает bytes). rb: `:text` → String
  UTF-8, `:binary` → String ASCII-8BIT, `:json` → Hash/Array.

### Array как body
- rb явно принимает `Array` → `application/json`. py проверяет только str/dict.

---

## Storage (`lib/supabase/storage/`)

### `analytics.catalog()` возвращает `Hash`, а не `RestCatalog`
- py: живой `pyiceberg.RestCatalog` (`_sync/analytics.py:54-81`).
- rb: Hash конфигурации (`storage/analytics.rb:51-66`) — в Ruby-экосистеме
  нет Iceberg-клиента. Документированное ограничение, не баг.

### `exists?` ловит `StorageApiError`, а не `JSONDecodeError`
- py: `except json.JSONDecodeError` (`file_api.py:414-415`) — фактически
  мёртвая ветка для HEAD-ответа.
- rb: `rescue Errors::StorageApiError` (`file_api.rb:141-142`) — прямой
  перехват HTTP-ошибки. Наблюдаемое поведение одинаковое (false при ошибке).

### Код ошибки при не-JSON теле: `"InternalError"` вместо `"LibraryError"`
- py: `_sync/request.py:42-47` ставит code `"LibraryError"` + сырой текст.
- rb: `request.rb:39-47` ставит `"InternalError"` + `"HTTP <status>"`.
  Если матчитесь на code в обработке ошибок — учитывайте.

### Retry-логики нет — как и в py
- Ни одна из реализаций не ретраит storage-запросы (fail-fast). Это паритет;
  фиксируем, чтобы никто не «допортировал» несуществующий retry.

---

## Auth (`lib/supabase/auth/`)

### Явный список алгоритмов JWT
- py делегирует PyJWT (неявно); rb держит `SUPPORTED_ALGORITHMS` +
  `ALG_TO_DIGEST` (`auth/client.rb`) и на неизвестном алгоритме даёт чистый
  `AuthInvalidJwtError("Algorithm not supported")`. Список должен оставаться
  синхронным с дефолтами PyJWT.

### Логирование ошибок auto-refresh
- py молча глотает/ребросает ошибки рефреша; rb логирует через
  `_log_refresh_error` (logger → `Kernel.warn`) и не уходит в бесконечный
  ретрай на неретраябельных ошибках (`auth/client.rb:816-832`).

### `reset_password_email(email:, **options)` — keyword-аргумент
- py: позиционный `reset_password_email(email, options)`. Сигнатурное
  отличие, ломает только механический перенос кода.

### `Client#init` вместо `initialize()`
- py: метод `initialize()`. В Ruby имя занято конструктором — публичный метод
  называется `init` (алиас `bootstrap`).

### `Errors::AuthPKCEError`
- rb-only класс ошибки, в py отсутствует.

### Таймер — только треды
- py `Timer` умеет и threading, и asyncio-таски; rb — только `Thread`
  (`auth/timer.rb`). Формула backoff и константы (`MAX_RETRIES=10`,
  `RETRY_INTERVAL=2`, `EXPIRY_MARGIN=10s`, `JWKS_TTL=600s`) — паритет.

---

## Postgrest (`lib/supabase/postgrest/`)

### `not_` — метод, а не property
- py: `builder.not_.eq(...)` (property). rb: `builder.not_.eq(...)` — метод,
  возвращающий self. Внешне совпадает, реализация идиоматичная.

### `APIError` принимает и строковые, и символьные ключи
- py ждёт dict со строковыми ключами; rb — защитный `@raw["x"] || @raw[:x]`
  (`postgrest/errors.rb:9-47`).

### Нет deprecation-warning на `timeout:`
- py предупреждает о deprecated `timeout` в конструкторе клиента; rb молча
  принимает. Осознанно: добавим warning, когда будем выпиливать параметр.

### `maybe_single` — паритет (зафиксировано, чтобы не «чинили»)
- Для SELECT-цепочки `maybe_single` **не** ставит Accept-заголовок ни в py
  (`_sync/request_builder.py:217-219`), ни в rb (`request_builder.rb:513-515`);
  для RPC — ставит в обеих (`base_request_builder.py:671-674` ↔
  `request_builder.rb:572-575`). Ревью 2026-06-11 проверило это вручную —
  кажущаяся асимметрия в rb-коде повторяет py точно.

---

## Тестовая стратегия

- Юнит-паритет: rb-спеки помечены `US-XXX` с отсылкой к py-поведению.
- Живые интеграционные тесты realtime: `spec/integration/realtime_smoke_spec.rb`
  (US-049) и `spec/integration/realtime_live_spec.rb` (US-051, зеркалит
  py `test_connection.py` / `test_presence.py`). Гейтятся на
  `SUPABASE_INTEGRATION_URL` / `SUPABASE_INTEGRATION_KEY`; без них — skip.
