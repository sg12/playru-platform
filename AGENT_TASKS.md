# AGENT 1 — playru-platform
## Бэкенд платформы: Nakama + Django + PostgreSQL + K8s

> **Инструкция агенту:**
> Выполняй задачи строго по порядку. После каждой задачи запускай приёмочные тесты.
> НЕ ПЕРЕХОДИ к следующей задаче пока все тесты текущей не прошли (все зелёные).
> Останови работу только когда весь раздел "ФИНАЛЬНАЯ ПРИЁМКА" пройден полностью.

---

## СТЕК
- **Nakama** — игровой бэкенд (Apache 2.0)
- **Django 4.2+** — веб-платформа, каталог игр, Admin
- **PostgreSQL 15** — единая БД (Nakama + Django)
- **Docker Compose** — локальная разработка
- **Python 3.11+**

---

## ЗАДАЧА 1 — Структура репозитория

Создай следующую структуру папок и файлов:

```
playru-platform/
├── docker-compose.yml          # Nakama + PostgreSQL + Django
├── .env.example                # Все переменные окружения
├── .gitignore
├── README.md
├── nakama/
│   ├── config/
│   │   └── config.yml          # Конфиг Nakama сервера
│   └── modules/                # Lua/TypeScript модули (пустая папка)
├── backend/                    # Django проект
│   ├── manage.py
│   ├── requirements.txt
│   ├── config/
│   │   ├── __init__.py
│   │   ├── settings/
│   │   │   ├── base.py
│   │   │   ├── development.py
│   │   │   └── production.py
│   │   ├── urls.py
│   │   └── wsgi.py
│   ├── apps/
│   │   ├── games/              # Каталог игр
│   │   │   ├── __init__.py
│   │   │   ├── models.py
│   │   │   ├── views.py
│   │   │   ├── serializers.py
│   │   │   ├── urls.py
│   │   │   └── admin.py
│   │   └── platform/           # Общие модели платформы
│   │       ├── __init__.py
│   │       ├── models.py
│   │       ├── views.py
│   │       └── urls.py
│   └── tests/
│       ├── test_games.py
│       └── test_platform.py
└── k8s/                        # Kubernetes манифесты (заготовки)
    ├── namespace.yaml
    ├── postgres/
    ├── nakama/
    └── django/
```

### Приёмочные тесты задачи 1:
```bash
# Все эти команды должны выполниться без ошибок:
test -f docker-compose.yml && echo "OK: docker-compose.yml"
test -f .env.example && echo "OK: .env.example"
test -f backend/manage.py && echo "OK: Django manage.py"
test -d nakama/modules && echo "OK: nakama/modules"
test -d backend/apps/games && echo "OK: games app"
test -d k8s && echo "OK: k8s manifests dir"
```

---

## ЗАДАЧА 2 — Docker Compose с Nakama + PostgreSQL

Создай `docker-compose.yml` со следующими сервисами:

1. **postgres** — PostgreSQL 15, два пользователя: `nakama_user` и `django_user`, две базы: `nakama` и `playru`
2. **nakama** — версия 3.x последняя стабильная, подключён к postgres, порты 7349, 7350, 7351
3. **django** — Django с hot-reload через watchfiles, порт 8000
4. **adminer** — веб-интерфейс для БД, порт 8080 (только для dev)

Создай `.env.example`:
```
# PostgreSQL
POSTGRES_PASSWORD=changeme
NAKAMA_DB_PASSWORD=changeme
DJANGO_DB_PASSWORD=changeme

# Nakama
NAKAMA_SERVER_KEY=playru-server-key
NAKAMA_ENCRYPTION_KEY=changeme-must-be-16chars

# Django
DJANGO_SECRET_KEY=changeme-very-long-secret-key
DJANGO_DEBUG=True
DJANGO_ALLOWED_HOSTS=localhost,127.0.0.1

# VK OAuth (заполнить позже)
VK_APP_ID=
VK_APP_SECRET=

# Yandex OAuth (заполнить позже)
YANDEX_CLIENT_ID=
YANDEX_CLIENT_SECRET=
```

Создай `nakama/config/config.yml`:
```yaml
name: playru
data_dir: /nakama/data
logger:
  level: INFO
session:
  token_expiry_sec: 86400
runtime:
  lua_min_count: 2
  lua_max_count: 32
  lua_call_stack_size: 128
  lua_registry_size: 512
```

### Приёмочные тесты задачи 2:
```bash
# Запусти и проверь что все сервисы поднялись:
docker compose up -d
sleep 15

# PostgreSQL доступен:
docker compose exec postgres pg_isready -U postgres && echo "OK: PostgreSQL ready"

# Nakama HTTP API отвечает:
curl -sf http://localhost:7350/ | python3 -c "import sys,json; d=json.load(sys.stdin); print('OK: Nakama', d.get('version','?'))"

# Adminer доступен:
curl -sf http://localhost:8080/ | grep -q "Adminer" && echo "OK: Adminer ready"

# Обе БД существуют:
docker compose exec postgres psql -U postgres -c "\l" | grep -q "nakama" && echo "OK: nakama DB exists"
docker compose exec postgres psql -U postgres -c "\l" | grep -q "playru" && echo "OK: playru DB exists"

docker compose down
```

---

## ЗАДАЧА 3 — Django проект: модели и API каталога игр

### 3.1 Настройки Django

В `backend/config/settings/base.py` настрой:
- INSTALLED_APPS включает `apps.games`, `apps.platform`, `rest_framework`, `corsheaders`
- Database: PostgreSQL из env переменных
- REST_FRAMEWORK: базовая конфигурация с JSON рендерером
- CORS: разрешить все origins в development

requirements.txt должен содержать:
```
Django>=4.2,<5.0
djangorestframework>=3.14
django-cors-headers>=4.0
psycopg2-binary>=2.9
python-dotenv>=1.0
Pillow>=10.0
pytest-django>=4.7
pytest>=7.4
factory-boy>=3.3
```

### 3.2 Модель Game

В `backend/apps/games/models.py` создай модель:

```python
class Game(models.Model):
    class Status(models.TextChoices):
        DRAFT = 'draft', 'Черновик'
        PUBLISHED = 'published', 'Опубликована'
        ARCHIVED = 'archived', 'Архив'

    title = models.CharField(max_length=200, verbose_name='Название')
    slug = models.SlugField(unique=True)
    description = models.TextField(verbose_name='Описание')
    short_description = models.CharField(max_length=300, verbose_name='Краткое описание')
    thumbnail = models.ImageField(upload_to='games/thumbnails/', null=True, blank=True)
    
    # Игровые данные
    nakama_match_label = models.CharField(max_length=100, blank=True)
    lua_module_name = models.CharField(max_length=100, blank=True)
    max_players = models.PositiveSmallIntegerField(default=10)
    min_players = models.PositiveSmallIntegerField(default=1)
    
    # Метрики
    play_count = models.PositiveBigIntegerField(default=0)
    active_players = models.PositiveIntegerField(default=0)
    
    # Мета
    status = models.CharField(max_length=20, choices=Status.choices, default=Status.DRAFT)
    is_featured = models.BooleanField(default=False)
    tags = models.JSONField(default=list, blank=True)
    
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)
    
    class Meta:
        verbose_name = 'Игра'
        verbose_name_plural = 'Игры'
        ordering = ['-play_count']
    
    def __str__(self):
        return self.title
```

### 3.3 REST API

Создай endpoints:
- `GET /api/v1/games/` — список опубликованных игр (пагинация 20)
- `GET /api/v1/games/<slug>/` — детали игры
- `GET /api/v1/games/featured/` — рекомендованные игры
- `POST /api/v1/games/<slug>/play/` — инкремент play_count (для клиента)

### 3.4 Django Admin

В `admin.py` зарегистрируй Game с полями:
- list_display: title, status, play_count, active_players, is_featured, created_at
- list_filter: status, is_featured
- search_fields: title, description
- prepopulated_fields: slug из title

### Приёмочные тесты задачи 3:
```bash
cd backend
pip install -r requirements.txt

# Миграции создаются без ошибок:
python manage.py makemigrations --check 2>/dev/null || python manage.py makemigrations
python manage.py migrate && echo "OK: Migrations applied"

# Django запускается:
python manage.py check && echo "OK: Django check passed"

# Юнит-тесты:
pytest tests/test_games.py -v

# API отвечает (запусти сервер в фоне):
python manage.py runserver &
sleep 3
curl -sf http://localhost:8000/api/v1/games/ | python3 -c "import sys,json; d=json.load(sys.stdin); print('OK: Games API, count=', d.get('count',0))"
kill %1
```

Напиши тесты в `tests/test_games.py` которые проверяют:
- Создание Game модели через factory
- GET /api/v1/games/ возвращает 200 и список
- GET /api/v1/games/featured/ возвращает только is_featured=True
- Game со статусом draft не попадает в API
- POST /api/v1/games/<slug>/play/ инкрементирует play_count

---

## ЗАДАЧА 4 — Nakama: базовая конфигурация и healthcheck

### 4.1 Lua модуль инициализации

Создай `nakama/modules/init.lua`:

```lua
-- PlayRU Platform - Nakama Initialization Module
local nk = require("nakama")

-- Регистрация RPC функций платформы
local function register_rpcs()
    -- Health check
    nk.register_rpc(function(context, payload)
        return nk.json_encode({
            status = "ok",
            platform = "PlayRU",
            version = "0.1.0",
            server_time = nk.time()
        })
    end, "platform/health")
    
    -- Получить список игр (заглушка — будет заменена на запрос к Django)
    nk.register_rpc(function(context, payload)
        return nk.json_encode({
            games = {},
            message = "Game catalog coming soon"
        })
    end, "platform/games/list")
end

-- Хук на создание аккаунта
local function on_account_created(context, logger, nk, data)
    logger:info("New account created: " .. data.user_id)
    
    -- Выдать стартовый баланс PlayCoin
    local changeset = {
        playcoin = 100  -- 100 стартовых монет
    }
    local metadata = {source = "welcome_bonus"}
    
    nk.wallet_update(data.user_id, changeset, metadata, true)
    logger:info("Welcome bonus 100 PlayCoin given to: " .. data.user_id)
end

-- Инициализация
register_rpcs()
nk.register_rt_before(function(context, logger, nk, envelope)
    logger:debug("RT message before: " .. tostring(envelope))
    return envelope
end, "ChannelJoin")

return {}
```

### 4.2 Обновить docker-compose с Lua модулем

Добавь в сервис nakama volume mount:
```yaml
volumes:
  - ./nakama/modules:/nakama/data/modules
  - ./nakama/config/config.yml:/nakama/config.yml
```

### Приёмочные тесты задачи 4:
```bash
docker compose up -d
sleep 20

# Nakama Console доступна:
curl -sf http://localhost:7351/ | grep -q "Nakama" && echo "OK: Nakama Console accessible"

# RPC health check работает:
# Сначала получаем session token
AUTH=$(curl -sf -X POST "http://localhost:7350/v2/account/authenticate/device?create=true&username=testuser_$$" \
  -H "Content-Type: application/json" \
  -u "playru-server-key:" \
  -d '{"id":"test-device-'$$'"}' | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

echo "Auth token: ${AUTH:0:20}..."

# Вызываем RPC
curl -sf -X POST "http://localhost:7350/v2/rpc/platform%2Fhealth" \
  -H "Authorization: Bearer $AUTH" \
  -H "Content-Type: application/json" \
  -d '{}' | python3 -c "
import sys, json
d = json.load(sys.stdin)
payload = json.loads(d.get('payload', '{}').strip('\"').replace('\\\\\"', '\"'))
assert payload.get('status') == 'ok', f'Expected ok, got {payload}'
print('OK: Nakama RPC health check passed')
"

# Проверяем что стартовый баланс создаётся при регистрации:
WALLET=$(curl -sf "http://localhost:7350/v2/account" \
  -H "Authorization: Bearer $AUTH" | python3 -c "
import sys, json
d = json.load(sys.stdin)
wallet = d.get('wallet', '{}')
if isinstance(wallet, str):
    wallet = json.loads(wallet)
playcoin = wallet.get('playcoin', 0)
assert int(playcoin) == 100, f'Expected 100 playcoin, got {playcoin}'
print(f'OK: Welcome bonus {playcoin} PlayCoin confirmed')
")
echo $WALLET

docker compose down
```

---

## ЗАДАЧА 5 — VK OAuth интеграция в Nakama

### 5.1 Lua модуль VK аутентификации

Создай `nakama/modules/auth_vk.lua`:

```lua
-- VK OAuth Custom Authentication for PlayRU
local nk = require("nakama")

-- VK Custom Auth RPC
-- Клиент передаёт: { "vk_token": "...", "device_id": "..." }
-- Сервер: верифицирует токен через VK API, создаёт/находит аккаунт
local function vk_authenticate(context, payload)
    local data = nk.json_decode(payload)
    
    if not data or not data.vk_token then
        error("Missing vk_token in payload")
    end
    
    -- Запрос к VK API для получения user_id
    local success, res_headers, res_body = pcall(function()
        return nk.http_request(
            "https://api.vk.com/method/users.get?access_token=" .. data.vk_token .. "&v=5.131&fields=photo_100",
            "GET",
            {["Content-Type"] = "application/json"},
            nil
        )
    end)
    
    if not success then
        error("VK API request failed: " .. tostring(res_headers))
    end
    
    local vk_data = nk.json_decode(res_body)
    
    if not vk_data or not vk_data.response or #vk_data.response == 0 then
        error("Invalid VK token or empty response")
    end
    
    local vk_user = vk_data.response[1]
    local vk_id = tostring(vk_user.id)
    local display_name = vk_user.first_name .. " " .. vk_user.last_name
    local avatar_url = vk_user.photo_100 or ""
    
    -- Создаём или находим аккаунт по VK ID
    local user_id, _, created = nk.authenticate_custom(vk_id, "vk_" .. vk_id, true)
    
    -- Обновляем профиль если новый пользователь
    if created then
        nk.account_update_id(user_id, "vk_" .. vk_id, display_name, avatar_url, nil, nil, nil, nil)
        nk.logger_info("New VK user registered: " .. vk_id .. " / " .. display_name)
    end
    
    -- Генерируем Nakama session token
    local token, _ = nk.authenticate_custom(vk_id, "vk_" .. vk_id, false)
    
    return nk.json_encode({
        user_id = user_id,
        display_name = display_name,
        avatar_url = avatar_url,
        is_new = created,
        nakama_token = token
    })
end

nk.register_rpc(vk_authenticate, "auth/vk")

return {}
```

### 5.2 Обновить init.lua

Добавь в начало `init.lua`:
```lua
require("auth_vk")
```

### Приёмочные тесты задачи 5:
```bash
docker compose up -d
sleep 20

# Модуль загружается без ошибок (проверяем лог Nakama):
docker compose logs nakama | grep -E "(ERROR|WARN|auth_vk)" | grep -v "INFO" | head -5
docker compose logs nakama | grep -q "auth/vk" && echo "OK: VK auth RPC registered" || echo "INFO: Module loaded (RPC check)"

# RPC endpoint существует (вернёт ошибку токена, но не 404):
AUTH=$(curl -sf -X POST "http://localhost:7350/v2/account/authenticate/device?create=true" \
  -H "Content-Type: application/json" \
  -u "playru-server-key:" \
  -d '{"id":"test-device-vk-'$$'"}' | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

RESULT=$(curl -s -X POST "http://localhost:7350/v2/rpc/auth%2Fvk" \
  -H "Authorization: Bearer $AUTH" \
  -H "Content-Type: application/json" \
  -d '{"vk_token":"invalid_test_token"}')

# Должна быть ошибка токена (не 404 "rpc not found"):
echo $RESULT | python3 -c "
import sys, json
d = json.load(sys.stdin)
msg = d.get('message', '') + d.get('error', '')
assert 'not found' not in msg.lower(), f'RPC not registered: {msg}'
print('OK: VK auth RPC exists (returns expected token error)')
"

docker compose down
```

---

## ЗАДАЧА 6 — Django: seed данных и финальный smoke test

### 6.1 Management команда для seed

Создай `backend/apps/games/management/commands/seed_games.py`:

Команда `python manage.py seed_games` должна создать 5 тестовых игр:
1. **parkour-simulator** — Паркур Симулятор (is_featured=True, status=published)
2. **arena-shooter** — Арена Стрелялок (is_featured=True, status=published)
3. **clicker-world** — Кликер Мир (status=published)
4. **racing-chaos** — Хаос Гонки (status=published)
5. **island-survival** — Выживание на Острове (status=draft)

### 6.2 Финальный интеграционный тест

Создай `tests/test_integration.py` — тест который поднимает Docker Compose и проверяет всё сквозно.

### Приёмочные тесты задачи 6:
```bash
cd backend
python manage.py seed_games && echo "OK: Seed data created"

# Проверка данных:
python manage.py shell -c "
from apps.games.models import Game
total = Game.objects.count()
published = Game.objects.filter(status='published').count()
featured = Game.objects.filter(is_featured=True).count()
assert total == 5, f'Expected 5 games, got {total}'
assert published == 4, f'Expected 4 published, got {published}'
assert featured == 2, f'Expected 2 featured, got {featured}'
print(f'OK: Seed data verified: {total} games, {published} published, {featured} featured')
"

# API возвращает правильные данные:
python manage.py runserver &
sleep 3

curl -sf http://localhost:8000/api/v1/games/ | python3 -c "
import sys, json
d = json.load(sys.stdin)
count = d.get('count', 0)
assert count == 4, f'Expected 4 published games in API, got {count}'
print(f'OK: API returns {count} published games (draft excluded)')
"

curl -sf http://localhost:8000/api/v1/games/featured/ | python3 -c "
import sys, json
d = json.load(sys.stdin)
results = d.get('results', d) if isinstance(d, dict) else d
count = len(results) if isinstance(results, list) else d.get('count', 0)
assert count >= 2, f'Expected 2+ featured games, got {count}'
print(f'OK: Featured API returns {count} games')
"

kill %1
```

---

## ✅ ФИНАЛЬНАЯ ПРИЁМКА — запусти всё вместе

```bash
# Полный интеграционный тест:
docker compose up -d
sleep 20

# 1. Все контейнеры запущены:
docker compose ps | grep -c "Up" | xargs -I{} bash -c 'if [ "{}" -ge 3 ]; then echo "OK: {} containers running"; else echo "FAIL: only {} containers"; exit 1; fi'

# 2. PostgreSQL:
docker compose exec postgres pg_isready && echo "OK: PostgreSQL"

# 3. Nakama API:
curl -sf http://localhost:7350/ > /dev/null && echo "OK: Nakama API"

# 4. Nakama RPC health:
AUTH=$(curl -sf -X POST "http://localhost:7350/v2/account/authenticate/device?create=true" \
  -u "playru-server-key:" \
  -H "Content-Type: application/json" \
  -d '{"id":"final-test-device"}' | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")
curl -sf -X POST "http://localhost:7350/v2/rpc/platform%2Fhealth" \
  -H "Authorization: Bearer $AUTH" -d '{}' > /dev/null && echo "OK: Nakama RPC health"

# 5. Django API:
docker compose up django -d 2>/dev/null || true
curl -sf http://localhost:8000/api/v1/games/ > /dev/null && echo "OK: Django Games API"

# 6. Все юнит-тесты:
cd backend && pytest tests/ -v --tb=short

echo ""
echo "================================================"
echo "  AGENT 1 ЗАДАЧА ВЫПОЛНЕНА — ВСЕ ТЕСТЫ ЗЕЛЁНЫЕ"
echo "================================================"
```

> **Агент останавливается здесь и ждёт команды от человека.**
