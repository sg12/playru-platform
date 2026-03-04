# AGENT 1 — playru-platform — ВОЛНА 3
## Третья игра (Кликер), K8s манифесты, сводный лидерборд

> **Инструкция агенту:**
> Продолжаем в том же репозитории playru-platform.
> Docker Compose работает, все предыдущие модули активны.
> Выполняй задачи строго по порядку.
> После каждой задачи запускай приёмочные тесты — все должны быть зелёные.
> Останови работу только когда ФИНАЛЬНАЯ ПРИЁМКА пройдена полностью.

---

## ЗАДАЧА 11 — Третья игра: Кликер (Lua модуль)

Создай `nakama/modules/games/clicker.lua`:

```lua
-- PlayRU: Clicker World — Server Logic
-- Простой idle-кликер: тапаешь, копишь очки, покупаешь улучшения
local nk = require("nakama")

local UPGRADES = {
    auto_clicker    = {cost = 100,  cps = 1,   name = "Авто-кликер"},
    fast_fingers    = {cost = 500,  cps = 5,   name = "Быстрые пальцы"},
    click_machine   = {cost = 2000, cps = 20,  name = "Кликер-машина"},
    robot_army      = {cost = 10000,cps = 100, name = "Армия роботов"},
}

-- Загрузить состояние игры игрока
local function load_state(user_id)
    local objects = nk.storage_read({
        {collection = "clicker", key = "state", user_id = user_id}
    })
    if #objects > 0 then
        return nk.json_decode(objects[1].value)
    end
    return {
        total_clicks = 0,
        score = 0,
        upgrades = {},
        last_save = nk.time()
    }
end

-- Сохранить состояние
local function save_state(user_id, state)
    state.last_save = nk.time()
    nk.storage_write({
        {
            collection = "clicker",
            key = "state",
            user_id = user_id,
            value = nk.json_encode(state),
            permission_read = 1,
            permission_write = 1
        }
    })
end

-- RPC: Синхронизация кликов (клиент отправляет пачку кликов)
local function clicker_sync(context, payload)
    local data = nk.json_decode(payload)
    if not data or not data.clicks then
        error("Missing clicks in payload")
    end

    local user_id = context.user_id
    local clicks = math.min(data.clicks, 1000) -- максимум 1000 за раз (анти-чит)
    local state = load_state(user_id)

    -- Считаем CPS от улучшений
    local cps = 0
    for upgrade_id, level in pairs(state.upgrades) do
        if UPGRADES[upgrade_id] then
            cps = cps + UPGRADES[upgrade_id].cps * level
        end
    end

    -- Считаем оффлайн прогресс (максимум 4 часа)
    local elapsed = math.min((nk.time() - state.last_save) / 1000, 14400)
    local offline_score = math.floor(cps * elapsed)

    state.total_clicks = state.total_clicks + clicks
    state.score = state.score + clicks + offline_score

    save_state(user_id, state)

    -- Лидерборд по очкам
    nk.leaderboard_records_write("clicker_score", {
        {owner_id = user_id, score = state.score, subscore = state.total_clicks}
    })

    -- PlayCoin за каждые 100 кликов
    local coins = math.floor(clicks / 100)
    if coins > 0 then
        nk.wallet_update(user_id, {playcoin = coins},
            {source = "clicker_clicks", clicks = clicks}, true)
    end

    return nk.json_encode({
        score = state.score,
        total_clicks = state.total_clicks,
        offline_score = offline_score,
        cps = cps,
        coins_earned = coins
    })
end

-- RPC: Купить улучшение
local function clicker_buy_upgrade(context, payload)
    local data = nk.json_decode(payload)
    if not data or not data.upgrade_id then
        error("Missing upgrade_id")
    end

    local upgrade_id = data.upgrade_id
    local upgrade = UPGRADES[upgrade_id]
    if not upgrade then
        error("Unknown upgrade: " .. upgrade_id)
    end

    local user_id = context.user_id
    local state = load_state(user_id)
    local level = (state.upgrades[upgrade_id] or 0)
    local cost = upgrade.cost * (level + 1)

    if state.score < cost then
        return nk.json_encode({
            success = false,
            message = "Недостаточно очков. Нужно: " .. cost,
            current_score = state.score
        })
    end

    state.score = state.score - cost
    state.upgrades[upgrade_id] = level + 1
    save_state(user_id, state)

    return nk.json_encode({
        success = true,
        upgrade_id = upgrade_id,
        new_level = level + 1,
        cost = cost,
        remaining_score = state.score,
        message = upgrade.name .. " улучшен до уровня " .. (level + 1)
    })
end

-- RPC: Получить состояние
local function clicker_get_state(context, payload)
    local state = load_state(context.user_id)
    local upgrades_info = {}
    for id, upgrade in pairs(UPGRADES) do
        local level = state.upgrades[id] or 0
        table.insert(upgrades_info, {
            id = id,
            name = upgrade.name,
            level = level,
            cps = upgrade.cps,
            cost = upgrade.cost * (level + 1)
        })
    end
    state.upgrades_info = upgrades_info
    return nk.json_encode(state)
end

-- Лидерборд
pcall(function()
    nk.leaderboard_create("clicker_score", true, "SCORE_DESC", "SCORE_DESC", false, {})
end)

nk.register_rpc(clicker_sync, "games/clicker/sync")
nk.register_rpc(clicker_buy_upgrade, "games/clicker/buy_upgrade")
nk.register_rpc(clicker_get_state, "games/clicker/state")

return {}
```

Добавь в `nakama/modules/init.lua`:
```lua
require("games/clicker")
```

Добавь в Django seed (`backend/apps/games/management/commands/seed_games.py`) шестую игру:
```python
Game.objects.get_or_create(
    slug='clicker-world',
    defaults={
        'title': 'Кликер Мир',
        'short_description': 'Тапай, собирай очки, покупай улучшения',
        'description': 'Простой idle-кликер. Тапай по экрану, зарабатывай очки, покупай улучшения для автоматического заработка. Соревнуйся в лидерборде!',
        'lua_module_name': 'clicker',
        'max_players': 1,
        'min_players': 1,
        'status': 'published',
        'is_featured': False,
        'tags': ['casual', 'idle', 'clicker'],
    }
)
```

### Приёмочные тесты задачи 11:
```bash
docker compose up -d
sleep 20

AUTH=$(curl -sf -X POST "http://localhost:7350/v2/account/authenticate/device?create=true&username=clicker_$$" \
  -u "playru-server-key:" -H "Content-Type: application/json" \
  -d '{"id":"clicker-test-'$$'"}' | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

# Получить начальное состояние:
curl -sf -X POST "http://localhost:7350/v2/rpc/games%2Fclicker%2Fstate" \
  -H "Authorization: Bearer $AUTH" -d '{}' | python3 -c "
import sys, json
d = json.load(sys.stdin)
payload = json.loads(d.get('payload','{}').strip('\"').replace('\\\\\"','\"'))
assert payload.get('total_clicks', -1) == 0, f'Expected 0 clicks: {payload}'
print('OK: Initial clicker state:', payload.get('score', 0), 'score')
"

# Синхронизировать 500 кликов:
curl -sf -X POST "http://localhost:7350/v2/rpc/games%2Fclicker%2Fsync" \
  -H "Authorization: Bearer $AUTH" -H "Content-Type: application/json" \
  -d '{"clicks": 500}' | python3 -c "
import sys, json
d = json.load(sys.stdin)
payload = json.loads(d.get('payload','{}').strip('\"').replace('\\\\\"','\"'))
assert payload.get('total_clicks', 0) == 500, f'Expected 500 clicks: {payload}'
assert payload.get('score', 0) >= 500, f'Score should be >= 500: {payload}'
print(f'OK: 500 clicks synced. Score: {payload[\"score\"]}')
"

# Купить улучшение (авто-кликер стоит 100):
curl -sf -X POST "http://localhost:7350/v2/rpc/games%2Fclicker%2Fbuy_upgrade" \
  -H "Authorization: Bearer $AUTH" -H "Content-Type: application/json" \
  -d '{"upgrade_id": "auto_clicker"}' | python3 -c "
import sys, json
d = json.load(sys.stdin)
payload = json.loads(d.get('payload','{}').strip('\"').replace('\\\\\"','\"'))
assert payload.get('success') == True, f'Buy should succeed: {payload}'
print(f'OK: Upgrade bought: {payload.get(\"message\")}')
"

# Попытка купить слишком дорогое улучшение:
curl -sf -X POST "http://localhost:7350/v2/rpc/games%2Fclicker%2Fbuy_upgrade" \
  -H "Authorization: Bearer $AUTH" -H "Content-Type: application/json" \
  -d '{"upgrade_id": "robot_army"}' | python3 -c "
import sys, json
d = json.load(sys.stdin)
payload = json.loads(d.get('payload','{}').strip('\"').replace('\\\\\"','\"'))
assert payload.get('success') == False, f'Should fail (not enough score): {payload}'
print('OK: Expensive upgrade correctly rejected')
"

# Django: шестая игра в каталоге:
cd backend
python manage.py seed_games
python manage.py runserver &
sleep 3
curl -sf "http://localhost:8000/api/v1/games/" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['count'] >= 5, f'Expected 5+ games, got {d[\"count\"]}'
print(f'OK: Catalog has {d[\"count\"]} games')
"
kill %1

docker compose down
```

---

## ЗАДАЧА 12 — Сводный лидерборд платформы

Создай `nakama/modules/platform_leaderboard.lua`:

```lua
-- PlayRU: Сводный лидерборд платформы
-- Агрегирует результаты по всем играм в единый рейтинг
local nk = require("nakama")

-- RPC: Топ игроков по суммарным PlayCoin
local function platform_top_players(context, payload)
    local data = nk.json_decode(payload or "{}")
    local limit = math.min((data and data.limit) or 10, 50)

    -- Получаем кошельки через wallet_ledger не работает напрямую,
    -- поэтому используем storage для агрегированной статистики
    local objects = nk.storage_read({})  -- заглушка

    -- Используем лидерборд суммарных очков
    local ok, records = pcall(function()
        local r, _, _, _ = nk.leaderboard_records_list(
            "platform_total_score", nil, limit, nil, 0)
        return r
    end)

    if not ok or not records then
        return nk.json_encode({
            players = {},
            message = "Leaderboard building..."
        })
    end

    local players = {}
    for i, record in ipairs(records) do
        table.insert(players, {
            rank = i,
            user_id = record.owner_id,
            total_score = record.score,
            games_played = record.subscore or 0
        })
    end

    return nk.json_encode({players = players, count = #players})
end

-- RPC: Обновить суммарный счёт игрока (вызывается после каждой игры)
local function platform_update_score(context, payload)
    local data = nk.json_decode(payload)
    if not data or not data.score then
        error("Missing score")
    end

    local user_id = context.user_id

    -- Читаем текущий суммарный счёт
    local objects = nk.storage_read({
        {collection = "platform", key = "total_score", user_id = user_id}
    })

    local current = {total_score = 0, games_played = 0}
    if #objects > 0 then
        current = nk.json_decode(objects[1].value)
    end

    current.total_score = current.total_score + data.score
    current.games_played = current.games_played + 1

    nk.storage_write({
        {
            collection = "platform",
            key = "total_score",
            user_id = user_id,
            value = nk.json_encode(current),
            permission_read = 2,
            permission_write = 1
        }
    })

    -- Обновляем суммарный лидерборд
    nk.leaderboard_records_write("platform_total_score", {
        {
            owner_id = user_id,
            score = current.total_score,
            subscore = current.games_played
        }
    })

    return nk.json_encode({
        total_score = current.total_score,
        games_played = current.games_played
    })
end

-- RPC: Статистика конкретного игрока
local function platform_player_stats(context, payload)
    local data = nk.json_decode(payload or "{}")
    local target_id = (data and data.user_id) or context.user_id

    local objects = nk.storage_read({
        {collection = "platform", key = "total_score", user_id = target_id}
    })

    if #objects == 0 then
        return nk.json_encode({
            user_id = target_id,
            total_score = 0,
            games_played = 0,
            message = "Нет данных"
        })
    end

    local stats = nk.json_decode(objects[1].value)
    stats.user_id = target_id
    return nk.json_encode(stats)
end

pcall(function()
    nk.leaderboard_create("platform_total_score", true, "SCORE_DESC", "SCORE_DESC", false, {})
end)

nk.register_rpc(platform_top_players, "platform/leaderboard")
nk.register_rpc(platform_update_score, "platform/update_score")
nk.register_rpc(platform_player_stats, "platform/player_stats")

return {}
```

Добавь в `init.lua`:
```lua
require("platform_leaderboard")
```

Обнови `nakama/modules/games/parkour.lua` — в конце функции `parkour_submit_score` добавь вызов:
```lua
-- Обновить суммарный счёт платформы
nk.run_once(function(ctx)
    -- nk.run_once не подходит здесь, используем прямой вызов
end)
-- После nk.wallet_update добавь:
nk.leaderboard_records_write("platform_total_score", {
    {owner_id = user_id, score = time_ms, subscore = 1}
})
```

### Приёмочные тесты задачи 12:
```bash
docker compose up -d
sleep 20

AUTH=$(curl -sf -X POST "http://localhost:7350/v2/account/authenticate/device?create=true&username=lb_$$" \
  -u "playru-server-key:" -H "Content-Type: application/json" \
  -d '{"id":"lb-test-'$$'"}' | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

# Обновить суммарный счёт:
curl -sf -X POST "http://localhost:7350/v2/rpc/platform%2Fupdate_score" \
  -H "Authorization: Bearer $AUTH" -H "Content-Type: application/json" \
  -d '{"score": 1500}' | python3 -c "
import sys, json
d = json.load(sys.stdin)
payload = json.loads(d.get('payload','{}').strip('\"').replace('\\\\\"','\"'))
assert payload.get('total_score', 0) >= 1500
print('OK: Platform score updated:', payload.get('total_score'))
"

# Статистика игрока:
curl -sf -X POST "http://localhost:7350/v2/rpc/platform%2Fplayer_stats" \
  -H "Authorization: Bearer $AUTH" -d '{}' | python3 -c "
import sys, json
d = json.load(sys.stdin)
payload = json.loads(d.get('payload','{}').strip('\"').replace('\\\\\"','\"'))
assert payload.get('games_played', 0) >= 1
print('OK: Player stats:', payload.get('games_played'), 'games played')
"

# Топ лидерборд:
curl -sf -X POST "http://localhost:7350/v2/rpc/platform%2Fleaderboard" \
  -H "Authorization: Bearer $AUTH" -d '{"limit": 5}' | python3 -c "
import sys, json
d = json.load(sys.stdin)
payload = json.loads(d.get('payload','{}').strip('\"').replace('\\\\\"','\"'))
assert 'players' in payload
print('OK: Platform leaderboard:', len(payload['players']), 'players')
"

docker compose down
```

---

## ЗАДАЧА 13 — K8s манифесты для production деплоя

Создай полную структуру `k8s/`:

```
k8s/
├── namespace.yaml
├── configmap.yaml
├── secrets.yaml.example       # НЕ содержит реальных секретов
├── postgres/
│   ├── deployment.yaml
│   ├── service.yaml
│   └── pvc.yaml
├── nakama/
│   ├── deployment.yaml
│   ├── service.yaml
│   └── configmap.yaml
└── django/
    ├── deployment.yaml
    ├── service.yaml
    └── ingress.yaml
```

**`k8s/namespace.yaml`**:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: playru
  labels:
    app: playru
    environment: production
```

**`k8s/postgres/deployment.yaml`**:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  namespace: playru
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
      - name: postgres
        image: postgres:15-alpine
        ports:
        - containerPort: 5432
        env:
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: playru-secrets
              key: postgres-password
        - name: POSTGRES_DB
          value: playru
        volumeMounts:
        - name: postgres-storage
          mountPath: /var/lib/postgresql/data
        resources:
          requests:
            memory: "256Mi"
            cpu: "250m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        livenessProbe:
          exec:
            command: ["pg_isready", "-U", "postgres"]
          initialDelaySeconds: 30
          periodSeconds: 10
      volumes:
      - name: postgres-storage
        persistentVolumeClaim:
          claimName: postgres-pvc
```

**`k8s/postgres/pvc.yaml`**:
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-pvc
  namespace: playru
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
```

**`k8s/postgres/service.yaml`**:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: playru
spec:
  selector:
    app: postgres
  ports:
  - port: 5432
    targetPort: 5432
  type: ClusterIP
```

**`k8s/nakama/deployment.yaml`**:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nakama
  namespace: playru
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nakama
  template:
    metadata:
      labels:
        app: nakama
    spec:
      containers:
      - name: nakama
        image: heroiclabs/nakama:3.22.0
        ports:
        - containerPort: 7349  # client port
        - containerPort: 7350  # HTTP API
        - containerPort: 7351  # console
        args:
        - "--config=/nakama/config.yml"
        - "--database.address=$(NAKAMA_DB_DSN)"
        env:
        - name: NAKAMA_DB_DSN
          valueFrom:
            secretKeyRef:
              name: playru-secrets
              key: nakama-db-dsn
        volumeMounts:
        - name: nakama-modules
          mountPath: /nakama/data/modules
        - name: nakama-config
          mountPath: /nakama/config.yml
          subPath: config.yml
        resources:
          requests:
            memory: "512Mi"
            cpu: "500m"
          limits:
            memory: "1Gi"
            cpu: "1000m"
        readinessProbe:
          httpGet:
            path: /
            port: 7350
          initialDelaySeconds: 20
          periodSeconds: 10
        livenessProbe:
          httpGet:
            path: /
            port: 7350
          initialDelaySeconds: 40
          periodSeconds: 30
      volumes:
      - name: nakama-modules
        configMap:
          name: nakama-modules
      - name: nakama-config
        configMap:
          name: nakama-config
```

**`k8s/nakama/service.yaml`**:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: nakama
  namespace: playru
spec:
  selector:
    app: nakama
  ports:
  - name: client
    port: 7349
    targetPort: 7349
  - name: http
    port: 7350
    targetPort: 7350
  - name: console
    port: 7351
    targetPort: 7351
  type: ClusterIP
```

**`k8s/django/deployment.yaml`**:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: django
  namespace: playru
spec:
  replicas: 2
  selector:
    matchLabels:
      app: django
  template:
    metadata:
      labels:
        app: django
    spec:
      containers:
      - name: django
        image: playru-backend:latest
        ports:
        - containerPort: 8000
        env:
        - name: DJANGO_SECRET_KEY
          valueFrom:
            secretKeyRef:
              name: playru-secrets
              key: django-secret-key
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: playru-secrets
              key: django-db-url
        - name: DJANGO_DEBUG
          value: "False"
        - name: DJANGO_ALLOWED_HOSTS
          value: "playru.ru,api.playru.ru"
        command: ["gunicorn", "config.wsgi:application",
                  "--bind", "0.0.0.0:8000",
                  "--workers", "4", "--timeout", "120"]
        resources:
          requests:
            memory: "256Mi"
            cpu: "250m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        readinessProbe:
          httpGet:
            path: /api/v1/platform/health/
            port: 8000
          initialDelaySeconds: 15
          periodSeconds: 10
```

**`k8s/django/ingress.yaml`**:
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: playru-ingress
  namespace: playru
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  tls:
  - hosts:
    - api.playru.ru
    secretName: playru-tls
  rules:
  - host: api.playru.ru
    http:
      paths:
      - path: /api
        pathType: Prefix
        backend:
          service:
            name: django
            port:
              number: 8000
      - path: /nakama
        pathType: Prefix
        backend:
          service:
            name: nakama
            port:
              number: 7350
```

**`k8s/secrets.yaml.example`**:
```yaml
# ПРИМЕР — не использовать в production напрямую!
# Создать реальный secrets.yaml и добавить в .gitignore
apiVersion: v1
kind: Secret
metadata:
  name: playru-secrets
  namespace: playru
type: Opaque
stringData:
  postgres-password: "CHANGE_ME"
  nakama-db-dsn: "postgresql://nakama_user:CHANGE_ME@postgres:5432/nakama"
  django-secret-key: "CHANGE_ME_VERY_LONG_SECRET"
  django-db-url: "postgresql://django_user:CHANGE_ME@postgres:5432/playru"
```

Добавь `k8s/secrets.yaml` в `.gitignore`.

### Приёмочные тесты задачи 13:
```bash
# Все файлы существуют:
for f in \
  k8s/namespace.yaml \
  k8s/secrets.yaml.example \
  k8s/postgres/deployment.yaml \
  k8s/postgres/service.yaml \
  k8s/postgres/pvc.yaml \
  k8s/nakama/deployment.yaml \
  k8s/nakama/service.yaml \
  k8s/django/deployment.yaml \
  k8s/django/ingress.yaml; do
    test -f "$f" && echo "OK: $f" || echo "FAIL: $f missing"
done

# YAML синтаксис валидный:
python3 -c "
import yaml, os, sys
errors = []
for root, dirs, files in os.walk('k8s'):
    for f in files:
        if f.endswith('.yaml') and 'secrets.yaml' not in f:
            path = os.path.join(root, f)
            try:
                with open(path) as fp:
                    yaml.safe_load(fp)
                print(f'OK: {path}')
            except Exception as e:
                errors.append(f'FAIL: {path}: {e}')
if errors:
    for e in errors: print(e)
    sys.exit(1)
print('OK: All YAML files valid')
"

# Ключевые поля в манифестах:
grep -q "namespace: playru" k8s/postgres/deployment.yaml && echo "OK: postgres namespace"
grep -q "namespace: playru" k8s/nakama/deployment.yaml && echo "OK: nakama namespace"
grep -q "replicas: 2" k8s/nakama/deployment.yaml && echo "OK: nakama replicas=2"
grep -q "replicas: 2" k8s/django/deployment.yaml && echo "OK: django replicas=2"
grep -q "livenessProbe" k8s/postgres/deployment.yaml && echo "OK: postgres health probe"
grep -q "readinessProbe" k8s/django/deployment.yaml && echo "OK: django readiness probe"
grep -q "playru-secrets" k8s/nakama/deployment.yaml && echo "OK: secrets reference"
grep -q "storage: 10Gi" k8s/postgres/pvc.yaml && echo "OK: postgres storage"
grep -q "letsencrypt" k8s/django/ingress.yaml && echo "OK: TLS ingress"
grep -q "secrets.yaml" .gitignore 2>/dev/null || \
  echo "secrets.yaml" >> .gitignore && echo "OK: secrets in gitignore"
```

---

## ЗАДАЧА 14 — Django: Dockerfile и gunicorn

Создай `backend/Dockerfile`:

```dockerfile
FROM python:3.11-slim

WORKDIR /app

# Системные зависимости
RUN apt-get update && apt-get install -y \
    libpq-dev gcc \
    && rm -rf /var/lib/apt/lists/*

# Python зависимости
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt \
    && pip install --no-cache-dir gunicorn psycopg2

# Приложение
COPY . .

# Статические файлы
RUN python manage.py collectstatic --noinput --settings=config.settings.production || true

EXPOSE 8000

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s \
    CMD curl -f http://localhost:8000/api/v1/platform/health/ || exit 1

CMD ["gunicorn", "config.wsgi:application", \
     "--bind", "0.0.0.0:8000", \
     "--workers", "4", \
     "--timeout", "120", \
     "--access-logfile", "-"]
```

Создай `backend/config/settings/production.py`:

```python
from .base import *
import os

DEBUG = False

SECRET_KEY = os.environ['DJANGO_SECRET_KEY']

ALLOWED_HOSTS = os.environ.get('DJANGO_ALLOWED_HOSTS', '').split(',')

# Database
DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': os.environ.get('POSTGRES_DB', 'playru'),
        'USER': os.environ.get('POSTGRES_USER', 'django_user'),
        'PASSWORD': os.environ.get('DJANGO_DB_PASSWORD'),
        'HOST': os.environ.get('POSTGRES_HOST', 'postgres'),
        'PORT': os.environ.get('POSTGRES_PORT', '5432'),
        'CONN_MAX_AGE': 60,
    }
}

# Security
SECURE_BROWSER_XSS_FILTER = True
SECURE_CONTENT_TYPE_NOSNIFF = True
X_FRAME_OPTIONS = 'DENY'

# Static files
STATIC_ROOT = '/app/staticfiles'
STATIC_URL = '/static/'

# Logging
LOGGING = {
    'version': 1,
    'disable_existing_loggers': False,
    'handlers': {
        'console': {
            'class': 'logging.StreamHandler',
        },
    },
    'root': {
        'handlers': ['console'],
        'level': 'INFO',
    },
}
```

### Приёмочные тесты задачи 14:
```bash
test -f backend/Dockerfile && echo "OK: Dockerfile"
test -f backend/config/settings/production.py && echo "OK: production settings"

grep -q "gunicorn" backend/Dockerfile && echo "OK: gunicorn in Dockerfile"
grep -q "HEALTHCHECK" backend/Dockerfile && echo "OK: Docker health check"
grep -q "collectstatic" backend/Dockerfile && echo "OK: static files"
grep -q "DJANGO_SECRET_KEY" backend/config/settings/production.py && echo "OK: secret key from env"
grep -q "CONN_MAX_AGE" backend/config/settings/production.py && echo "OK: DB connection pooling"

# Docker build (если Docker доступен):
if command -v docker &>/dev/null; then
    docker build -t playru-backend:test backend/ && echo "OK: Docker build successful" \
    || echo "WARN: Docker build failed (check logs)"
else
    echo "INFO: Docker not available locally, skipping build test"
fi
```

---

## ✅ ФИНАЛЬНАЯ ПРИЁМКА ВОЛНЫ 3

```bash
docker compose up -d
sleep 20
cd backend && python manage.py runserver &
sleep 3

echo "=== ФИНАЛЬНАЯ ПРИЁМКА ВОЛНЫ 3 ==="

AUTH=$(curl -sf -X POST "http://localhost:7350/v2/account/authenticate/device?create=true" \
  -u "playru-server-key:" -H "Content-Type: application/json" \
  -d '{"id":"final3-'$$'"}' | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

echo "--- Nakama RPCs (все 11) ---"
for rpc in \
  "auth%2Fvk" "auth%2Fyandex" \
  "economy%2Fwallet" "economy%2Fdaily_reward" \
  "platform%2Fhealth" "platform%2Fleaderboard" "platform%2Fupdate_score" \
  "games%2Fparkour%2Fsubmit_score" "games%2Fparkour%2Fleaderboard" \
  "games%2Farena%2Fsubmit_result" \
  "games%2Fclicker%2Fsync" "games%2Fclicker%2Fbuy_upgrade"; do
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
      "http://localhost:7350/v2/rpc/$rpc" \
      -H "Authorization: Bearer $AUTH" -d '{}')
    [ "$STATUS" != "404" ] && echo "OK: $rpc" || echo "FAIL: $rpc"
done

echo "--- Django endpoints ---"
for url in \
  "http://localhost:8000/api/v1/platform/health/" \
  "http://localhost:8000/api/v1/games/" \
  "http://localhost:8000/api/v1/games/featured/"; do
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$url")
    [ "$STATUS" = "200" ] && echo "OK: $url" || echo "FAIL: $url"
done

echo "--- K8s манифесты ---"
python3 -c "
import yaml, os
count = 0
for root, dirs, files in os.walk('k8s'):
    for f in files:
        if f.endswith('.yaml') and 'secrets' not in f:
            with open(os.path.join(root, f)) as fp:
                yaml.safe_load(fp)
            count += 1
print(f'OK: {count} K8s YAML files valid')
"

echo "--- Все тесты ---"
pytest tests/ -v --tb=short
FAILS=$(pytest tests/ 2>&1 | grep -c "FAILED" || true)

echo ""
if [ "$FAILS" -eq 0 ]; then
    echo "================================================"
    echo "  ВОЛНА 3 ВЫПОЛНЕНА — ВСЕ ТЕСТЫ ЗЕЛЁНЫЕ"
    echo "  Игр в Nakama: 3 (паркур + арена + кликер)"
    echo "  K8s манифесты: готовы к деплою"
    echo "  Docker: production-ready образ"
    echo "================================================"
else
    echo "FAIL: $FAILS тестов не прошли"
fi

kill %1 2>/dev/null
docker compose down
```

> **Агент останавливается здесь и ждёт команды от человека.**
