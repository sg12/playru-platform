# AGENT 1 — playru-platform — ВОЛНА 2
## Профили, Яндекс ID, PlayCoin API, эндпоинты для клиента

> **Инструкция агенту:**
> Продолжаем работу в том же репозитории playru-platform.
> Docker Compose уже работает — не пересоздавай его с нуля.
> Выполняй задачи строго по порядку.
> После каждой задачи запускай приёмочные тесты — все должны быть зелёные.
> Останови работу только когда весь раздел "ФИНАЛЬНАЯ ПРИЁМКА" пройден полностью.

---

## ЗАДАЧА 7 — Яндекс ID OAuth в Nakama

Создай `nakama/modules/auth_yandex.lua`:

```lua
-- Yandex ID OAuth Custom Authentication for PlayRU
local nk = require("nakama")

-- Яндекс ID Custom Auth RPC
-- Клиент передаёт: { "yandex_token": "..." }
local function yandex_authenticate(context, payload)
    local data = nk.json_decode(payload)

    if not data or not data.yandex_token then
        error("Missing yandex_token in payload")
    end

    -- Запрос к Yandex API для получения данных пользователя
    local success, res_headers, res_body = pcall(function()
        return nk.http_request(
            "https://login.yandex.ru/info?format=json",
            "GET",
            {
                ["Authorization"] = "OAuth " .. data.yandex_token,
                ["Content-Type"] = "application/json"
            },
            nil
        )
    end)

    if not success then
        error("Yandex API request failed: " .. tostring(res_headers))
    end

    local ya_data = nk.json_decode(res_body)

    if not ya_data or not ya_data.id then
        error("Invalid Yandex token or empty response")
    end

    local ya_id = tostring(ya_data.id)
    local display_name = ya_data.display_name or ya_data.login or "Игрок"
    local avatar_url = ""
    if ya_data.default_avatar_id then
        avatar_url = "https://avatars.yandex.net/get-yapic/" .. ya_data.default_avatar_id .. "/islands-200"
    end

    -- Создаём или находим аккаунт по Яндекс ID
    local user_id, _, created = nk.authenticate_custom(ya_id, "ya_" .. ya_id, true)

    if created then
        nk.account_update_id(user_id, "ya_" .. ya_id, display_name, avatar_url, nil, nil, nil, nil)
        -- Стартовый бонус уже выдаётся через хук on_account_created в init.lua
        nk.logger_info("New Yandex user registered: " .. ya_id .. " / " .. display_name)
    end

    return nk.json_encode({
        user_id = user_id,
        display_name = display_name,
        avatar_url = avatar_url,
        is_new = created,
        provider = "yandex"
    })
end

nk.register_rpc(yandex_authenticate, "auth/yandex")

return {}
```

Обнови `nakama/modules/init.lua` — добавь строку:
```lua
require("auth_yandex")
```

### Приёмочные тесты задачи 7:
```bash
docker compose up -d
sleep 20

# Модуль зарегистрирован:
AUTH=$(curl -sf -X POST "http://localhost:7350/v2/account/authenticate/device?create=true" \
  -u "playru-server-key:" -H "Content-Type: application/json" \
  -d '{"id":"test-ya-'$$'"}' | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

RESULT=$(curl -s -X POST "http://localhost:7350/v2/rpc/auth%2Fyandex" \
  -H "Authorization: Bearer $AUTH" -H "Content-Type: application/json" \
  -d '{"yandex_token":"invalid_test_token"}')

echo $RESULT | python3 -c "
import sys, json
d = json.load(sys.stdin)
msg = d.get('message', '') + d.get('error', '')
assert 'not found' not in msg.lower(), f'RPC not registered: {msg}'
print('OK: Yandex auth RPC exists')
"

# Оба auth RPC зарегистрированы:
for rpc in "auth%2Fvk" "auth%2Fyandex"; do
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
      "http://localhost:7350/v2/rpc/$rpc" \
      -H "Authorization: Bearer $AUTH" -d '{}')
    # 200 или 500 (ошибка токена) — оба означают что RPC существует, 404 = не найден
    [ "$STATUS" != "404" ] && echo "OK: $rpc exists (status $STATUS)" || echo "FAIL: $rpc not found"
done

docker compose down
```

---

## ЗАДАЧА 8 — Django: модель Profile + API для клиента

### 8.1 Модель UserProfile

Создай `backend/apps/platform/models.py`:

```python
from django.db import models
import uuid


class UserProfile(models.Model):
    """
    Профиль пользователя PlayRU.
    nakama_user_id — ID из Nakama, является основным идентификатором.
    """
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    nakama_user_id = models.CharField(max_length=100, unique=True, db_index=True)

    display_name = models.CharField(max_length=80, verbose_name='Имя игрока')
    avatar_url = models.URLField(blank=True, verbose_name='URL аватара')

    # Авторизация
    class AuthProvider(models.TextChoices):
        VK = 'vk', 'VK'
        YANDEX = 'yandex', 'Яндекс'
        GUEST = 'guest', 'Гость'

    auth_provider = models.CharField(
        max_length=20,
        choices=AuthProvider.choices,
        default=AuthProvider.GUEST
    )
    external_id = models.CharField(max_length=100, blank=True)

    # Статистика
    total_play_time_minutes = models.PositiveIntegerField(default=0)
    games_played = models.PositiveIntegerField(default=0)
    games_completed = models.PositiveIntegerField(default=0)

    # Мета
    is_banned = models.BooleanField(default=False)
    ban_reason = models.TextField(blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    last_seen = models.DateTimeField(auto_now=True)

    class Meta:
        verbose_name = 'Профиль'
        verbose_name_plural = 'Профили'
        ordering = ['-last_seen']

    def __str__(self):
        return f'{self.display_name} ({self.auth_provider})'
```

### 8.2 API эндпоинты для мобильного клиента

Создай `backend/apps/platform/views.py` со следующими endpoints:

**`GET /api/v1/profile/<nakama_user_id>/`** — получить профиль
**`POST /api/v1/profile/sync/`** — создать или обновить профиль из Nakama данных
  - Принимает: `{nakama_user_id, display_name, avatar_url, auth_provider}`
  - Возвращает: профиль + флаг `created`

**`GET /api/v1/platform/health/`** — health check платформы
  - Возвращает: `{status, version, games_count, profiles_count, server_time}`

**`GET /api/v1/games/<slug>/leaderboard/`** — топ-10 по игре (прокси к Nakama)
  - Пока возвращает заглушку: `{game_slug, records: [], message: "coming soon"}`

### 8.3 Django Admin для профилей

Зарегистрируй UserProfile в admin:
- list_display: display_name, auth_provider, games_played, is_banned, last_seen
- list_filter: auth_provider, is_banned
- search_fields: display_name, nakama_user_id
- readonly_fields: created_at, last_seen, total_play_time_minutes

### 8.4 Миграции

Создай и примени миграции для новой модели.

### Приёмочные тесты задачи 8:
```bash
cd backend
python manage.py makemigrations platform
python manage.py migrate && echo "OK: Migrations applied"
python manage.py check && echo "OK: Django check"

python manage.py runserver &
sleep 3

# Health check:
curl -sf http://localhost:8000/api/v1/platform/health/ | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d.get('status') == 'ok', f'Expected ok: {d}'
assert 'games_count' in d, 'Missing games_count'
print('OK: Platform health endpoint works, games_count=', d['games_count'])
"

# Profile sync (создание):
curl -sf -X POST http://localhost:8000/api/v1/profile/sync/ \
  -H "Content-Type: application/json" \
  -d '{"nakama_user_id":"test-uuid-123","display_name":"Тестовый Игрок","auth_provider":"guest"}' \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d.get('display_name') == 'Тестовый Игрок', f'Wrong name: {d}'
print('OK: Profile sync created:', d['display_name'], '| created=', d.get('created'))
"

# Profile get:
curl -sf http://localhost:8000/api/v1/profile/test-uuid-123/ | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d.get('nakama_user_id') == 'test-uuid-123', f'Wrong id: {d}'
print('OK: Profile GET works')
"

# Profile sync (обновление — повторный вызов):
curl -sf -X POST http://localhost:8000/api/v1/profile/sync/ \
  -H "Content-Type: application/json" \
  -d '{"nakama_user_id":"test-uuid-123","display_name":"Обновлённый Игрок","auth_provider":"vk"}' \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d.get('display_name') == 'Обновлённый Игрок', f'Update failed: {d}'
assert d.get('created') == False, 'Should not be created (already exists)'
print('OK: Profile sync update works')
"

# Leaderboard заглушка:
curl -sf http://localhost:8000/api/v1/games/parkour-simulator/leaderboard/ | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert 'records' in d, f'Missing records: {d}'
print('OK: Leaderboard endpoint works')
"

kill %1

# Юнит-тесты:
pytest tests/test_platform.py -v
```

Напиши тесты в `tests/test_platform.py`:
- Создание UserProfile через factory
- POST /api/v1/profile/sync/ создаёт профиль
- POST /api/v1/profile/sync/ обновляет существующий (не дублирует)
- GET /api/v1/profile/<id>/ возвращает 200
- GET /api/v1/profile/nonexistent/ возвращает 404
- GET /api/v1/platform/health/ возвращает status=ok

---

## ЗАДАЧА 9 — Nakama: система PlayCoin и кошелёк

Создай `nakama/modules/economy.lua`:

```lua
-- PlayRU Economy Module — PlayCoin система
local nk = require("nakama")

-- Константы наград
local REWARDS = {
    daily_login = 50,        -- ежедневный вход
    first_game_complete = 25, -- первое завершение игры в день
    invite_friend = 100,     -- пригласить друга
    level_complete = 10,     -- завершить уровень
}

-- RPC: Получить баланс кошелька
local function get_wallet(context, payload)
    local user_id = context.user_id
    local account = nk.account_get_id(user_id)
    local wallet = account.wallet or {}

    return nk.json_encode({
        user_id = user_id,
        playcoin = wallet.playcoin or 0,
        display = tostring(wallet.playcoin or 0) .. " PlayCoin"
    })
end

-- RPC: Ежедневная награда
local function claim_daily_reward(context, payload)
    local user_id = context.user_id
    local today = os.date("%Y-%m-%d")
    local storage_key = "daily_reward_" .. today

    -- Проверяем, получал ли уже сегодня
    local objects = nk.storage_read({
        {collection = "economy", key = storage_key, user_id = user_id}
    })

    if #objects > 0 then
        return nk.json_encode({
            success = false,
            message = "Ежедневная награда уже получена сегодня",
            next_claim_in_hours = 24
        })
    end

    -- Записываем факт получения
    nk.storage_write({
        {
            collection = "economy",
            key = storage_key,
            user_id = user_id,
            value = nk.json_encode({claimed_at = nk.time()}),
            permission_read = 1,
            permission_write = 0
        }
    })

    -- Начисляем монеты
    local amount = REWARDS.daily_login
    nk.wallet_update(user_id, {playcoin = amount},
        {source = "daily_reward", date = today}, true)

    nk.logger_info("Daily reward claimed: user=" .. user_id .. " amount=" .. amount)

    return nk.json_encode({
        success = true,
        coins_earned = amount,
        message = "+" .. amount .. " PlayCoin! Возвращайся завтра"
    })
end

-- RPC: История транзакций кошелька
local function get_wallet_history(context, payload)
    local data = nk.json_decode(payload or "{}")
    local limit = (data and data.limit) or 20
    local user_id = context.user_id

    local ledger, cursor = nk.wallet_ledger_list(user_id, limit)

    local history = {}
    for _, entry in ipairs(ledger) do
        table.insert(history, {
            id = entry.id,
            changeset = entry.changeset,
            metadata = entry.metadata,
            create_time = entry.create_time,
            update_time = entry.update_time
        })
    end

    return nk.json_encode({
        history = history,
        count = #history
    })
end

-- Регистрируем RPC
nk.register_rpc(get_wallet, "economy/wallet")
nk.register_rpc(claim_daily_reward, "economy/daily_reward")
nk.register_rpc(get_wallet_history, "economy/wallet_history")

return {}
```

Обнови `nakama/modules/init.lua`:
```lua
require("economy")
```

### Приёмочные тесты задачи 9:
```bash
docker compose up -d
sleep 20

AUTH=$(curl -sf -X POST "http://localhost:7350/v2/account/authenticate/device?create=true&username=econ_test_$$" \
  -u "playru-server-key:" -H "Content-Type: application/json" \
  -d '{"id":"econ-test-'$$'"}' | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

# Проверяем стартовый баланс (100 PlayCoin welcome bonus):
curl -sf -X POST "http://localhost:7350/v2/rpc/economy%2Fwallet" \
  -H "Authorization: Bearer $AUTH" -d '{}' | python3 -c "
import sys, json
d = json.load(sys.stdin)
payload = json.loads(d.get('payload', '{}').strip('\"').replace('\\\\\"','\"'))
coins = payload.get('playcoin', 0)
assert int(coins) == 100, f'Expected 100 welcome bonus, got {coins}'
print(f'OK: Wallet balance = {coins} PlayCoin (welcome bonus confirmed)')
"

# Ежедневная награда — первый запрос:
curl -sf -X POST "http://localhost:7350/v2/rpc/economy%2Fdaily_reward" \
  -H "Authorization: Bearer $AUTH" -d '{}' | python3 -c "
import sys, json
d = json.load(sys.stdin)
payload = json.loads(d.get('payload', '{}').strip('\"').replace('\\\\\"','\"'))
assert payload.get('success') == True, f'First claim should succeed: {payload}'
coins = payload.get('coins_earned', 0)
assert coins == 50, f'Expected 50 daily reward, got {coins}'
print(f'OK: Daily reward claimed: +{coins} PlayCoin')
"

# Ежедневная награда — повторный запрос (должен отказать):
curl -sf -X POST "http://localhost:7350/v2/rpc/economy%2Fdaily_reward" \
  -H "Authorization: Bearer $AUTH" -d '{}' | python3 -c "
import sys, json
d = json.load(sys.stdin)
payload = json.loads(d.get('payload', '{}').strip('\"').replace('\\\\\"','\"'))
assert payload.get('success') == False, f'Second claim should fail: {payload}'
print('OK: Duplicate daily reward correctly rejected')
"

# Баланс вырос до 150:
curl -sf -X POST "http://localhost:7350/v2/rpc/economy%2Fwallet" \
  -H "Authorization: Bearer $AUTH" -d '{}' | python3 -c "
import sys, json
d = json.load(sys.stdin)
payload = json.loads(d.get('payload', '{}').strip('\"').replace('\\\\\"','\"'))
coins = payload.get('playcoin', 0)
assert int(coins) == 150, f'Expected 150 (100 welcome + 50 daily), got {coins}'
print(f'OK: Total balance after daily reward = {coins} PlayCoin')
"

# История транзакций:
curl -sf -X POST "http://localhost:7350/v2/rpc/economy%2Fwallet_history" \
  -H "Authorization: Bearer $AUTH" -d '{}' | python3 -c "
import sys, json
d = json.load(sys.stdin)
payload = json.loads(d.get('payload', '{}').strip('\"').replace('\\\\\"','\"'))
count = payload.get('count', 0)
assert count >= 2, f'Expected at least 2 transactions, got {count}'
print(f'OK: Wallet history has {count} transactions')
"

docker compose down
```

---

## ЗАДАЧА 10 — Сквозной API тест: клиент может подключиться

Создай `tests/test_e2e_client_flow.py` — полный тест сценария мобильного клиента:

```python
"""
E2E тест: симуляция полного flow мобильного клиента PlayRU.
Этот тест запускается когда docker compose up активен.
Пропускается если Nakama или Django недоступны.
"""
import pytest
import requests
import json

NAKAMA_URL = "http://localhost:7350"
DJANGO_URL = "http://localhost:8000"
SERVER_KEY = "playru-server-key"

@pytest.fixture(scope="module")
def nakama_available():
    try:
        r = requests.get(f"{NAKAMA_URL}/", timeout=3)
        return r.status_code == 200
    except:
        return False

@pytest.fixture(scope="module")
def django_available():
    try:
        r = requests.get(f"{DJANGO_URL}/api/v1/platform/health/", timeout=3)
        return r.status_code == 200
    except:
        return False

@pytest.fixture(scope="module")
def auth_token(nakama_available):
    if not nakama_available:
        pytest.skip("Nakama unavailable")
    import time
    device_id = f"e2e-test-{int(time.time())}"
    r = requests.post(
        f"{NAKAMA_URL}/v2/account/authenticate/device?create=true",
        auth=(SERVER_KEY, ""),
        json={"id": device_id}
    )
    assert r.status_code == 200
    return r.json()["token"]

def rpc(token, rpc_id, payload=None):
    r = requests.post(
        f"{NAKAMA_URL}/v2/rpc/{rpc_id.replace('/', '%2F')}",
        headers={"Authorization": f"Bearer {token}"},
        json=payload or {}
    )
    assert r.status_code == 200, f"RPC {rpc_id} failed: {r.text}"
    data = r.json()
    raw = data.get("payload", "{}")
    if isinstance(raw, str):
        raw = raw.strip('"').replace('\\"', '"')
    return json.loads(raw)

class TestClientFlow:

    def test_01_platform_health_nakama(self, auth_token):
        """Клиент проверяет что платформа живая"""
        result = rpc(auth_token, "platform/health")
        assert result["status"] == "ok"
        assert result["platform"] == "PlayRU"
        print(f"  Platform version: {result.get('version')}")

    def test_02_wallet_welcome_bonus(self, auth_token):
        """Новый игрок получает 100 стартовых монет"""
        result = rpc(auth_token, "economy/wallet")
        assert result["playcoin"] >= 100
        print(f"  Wallet: {result['playcoin']} PlayCoin")

    def test_03_daily_reward(self, auth_token):
        """Игрок получает ежедневную награду"""
        result = rpc(auth_token, "economy/daily_reward")
        assert result["success"] == True
        assert result["coins_earned"] == 50
        print(f"  Daily reward: +{result['coins_earned']} PlayCoin")

    def test_04_daily_reward_duplicate(self, auth_token):
        """Повторный запрос ежедневной награды отклоняется"""
        result = rpc(auth_token, "economy/daily_reward")
        assert result["success"] == False
        print("  Duplicate daily reward: correctly rejected")

    def test_05_games_catalog_django(self, django_available):
        """Каталог игр возвращает данные"""
        if not django_available:
            pytest.skip("Django unavailable")
        r = requests.get(f"{DJANGO_URL}/api/v1/games/")
        assert r.status_code == 200
        data = r.json()
        assert data["count"] >= 4
        print(f"  Games catalog: {data['count']} games")

    def test_06_featured_games(self, django_available):
        """Рекомендованные игры возвращаются"""
        if not django_available:
            pytest.skip("Django unavailable")
        r = requests.get(f"{DJANGO_URL}/api/v1/games/featured/")
        assert r.status_code == 200
        data = r.json()
        results = data.get("results", data) if isinstance(data, dict) else data
        assert len(results) >= 2
        print(f"  Featured games: {len(results)}")

    def test_07_profile_sync(self, auth_token, django_available):
        """Профиль синхронизируется между Nakama и Django"""
        if not django_available:
            pytest.skip("Django unavailable")
        import time
        test_id = f"e2e-user-{int(time.time())}"
        r = requests.post(
            f"{DJANGO_URL}/api/v1/profile/sync/",
            json={
                "nakama_user_id": test_id,
                "display_name": "E2E Тест Игрок",
                "auth_provider": "guest"
            }
        )
        assert r.status_code in [200, 201]
        data = r.json()
        assert data["display_name"] == "E2E Тест Игрок"
        print(f"  Profile synced: {data['display_name']}")

    def test_08_parkour_submit_score(self, auth_token):
        """Результат паркура сохраняется и начисляются монеты"""
        wallet_before = rpc(auth_token, "economy/wallet")
        coins_before = wallet_before["playcoin"]

        result = rpc(auth_token, "games/parkour/submit_score", {
            "time": 42.5,
            "deaths": 2,
            "level": "level1"
        })
        assert result["success"] == True
        assert result["coins_earned"] > 0

        wallet_after = rpc(auth_token, "economy/wallet")
        coins_after = wallet_after["playcoin"]
        assert coins_after > coins_before
        print(f"  Score submitted: +{result['coins_earned']} PlayCoin ({coins_before} → {coins_after})")

    def test_09_parkour_leaderboard(self, auth_token):
        """Лидерборд паркура возвращает записи"""
        result = rpc(auth_token, "games/parkour/leaderboard", {"level": "level1"})
        assert "records" in result
        assert len(result["records"]) >= 1
        print(f"  Leaderboard: {len(result['records'])} records")

    def test_10_wallet_history_complete(self, auth_token):
        """История кошелька отражает все транзакции"""
        result = rpc(auth_token, "economy/wallet_history")
        assert result["count"] >= 3  # welcome + daily + parkour
        print(f"  Wallet history: {result['count']} transactions")
```

### Приёмочные тесты задачи 10:
```bash
# Поднимаем оба сервиса:
docker compose up -d
sleep 20

# Django в фоне:
cd backend && python manage.py runserver &
sleep 3

# Запускаем E2E тесты:
pytest tests/test_e2e_client_flow.py -v --tb=short

# Все 10 тестов должны пройти (или skip если сервис недоступен):
pytest tests/test_e2e_client_flow.py -v | grep -E "(PASSED|FAILED|SKIPPED|ERROR)"
FAILS=$(pytest tests/test_e2e_client_flow.py -v 2>&1 | grep -c "FAILED" || true)
[ "$FAILS" -eq 0 ] && echo "OK: All E2E tests passed" || echo "FAIL: $FAILS tests failed"

kill %1
docker compose down
```

---

## ✅ ФИНАЛЬНАЯ ПРИЁМКА ВОЛНЫ 2

```bash
docker compose up -d
sleep 20
cd backend && python manage.py runserver &
sleep 3

echo "=== ФИНАЛЬНАЯ ПРИЁМКА ВОЛНЫ 2 ==="

# Яндекс auth RPC существует:
AUTH=$(curl -sf -X POST "http://localhost:7350/v2/account/authenticate/device?create=true" \
  -u "playru-server-key:" -H "Content-Type: application/json" \
  -d '{"id":"final2-test"}' | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

for rpc in "auth%2Fvk" "auth%2Fyandex" "economy%2Fwallet" "economy%2Fdaily_reward" \
           "economy%2Fwallet_history" "platform%2Fhealth" \
           "games%2Fparkour%2Fsubmit_score" "games%2Fparkour%2Fleaderboard"; do
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
      "http://localhost:7350/v2/rpc/$rpc" \
      -H "Authorization: Bearer $AUTH" -d '{}')
    [ "$STATUS" != "404" ] && echo "OK: RPC $rpc" || echo "FAIL: $rpc not found"
done

# Django endpoints:
for url in \
  "http://localhost:8000/api/v1/platform/health/" \
  "http://localhost:8000/api/v1/games/" \
  "http://localhost:8000/api/v1/games/featured/"; do
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$url")
    [ "$STATUS" = "200" ] && echo "OK: $url" || echo "FAIL: $url returned $STATUS"
done

# Все тесты:
pytest tests/ -v --tb=short
FAILS=$(pytest tests/ 2>&1 | grep -c "FAILED" || true)
echo ""
[ "$FAILS" -eq 0 ] && echo "================================================" || true
[ "$FAILS" -eq 0 ] && echo "  ВОЛНА 2 ВЫПОЛНЕНА — ВСЕ ТЕСТЫ ЗЕЛЁНЫЕ" || echo "FAIL: $FAILS tests failed"
[ "$FAILS" -eq 0 ] && echo "================================================" || true

kill %1
docker compose down
```

> **Агент останавливается здесь и ждёт команды от человека.**
> 
> После завершения сообщи результат в формате такой же таблицы как после Волны 1.