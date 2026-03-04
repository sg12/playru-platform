# AGENT 1 — playru-platform — НЕДЕЛЯ 3
## Деплой на Selectel, мониторинг, подготовка к первым пользователям

> Продолжаем в playru-platform.
> CI/CD, ArgoCD манифесты, K8s YAML — всё готово из недели 2.
> Цель: платформа доступна по реальному URL, мониторинг работает,
> система готова выдержать первых 500 пользователей.
> После каждой задачи — приёмочные тесты. Стоп после ФИНАЛЬНОЙ ПРИЁМКИ.

---

## ЗАДАЧА 1 — Скрипты первичного деплоя на Selectel

Создай `scripts/deploy/` — полный набор скриптов для первого запуска в Selectel:

**`scripts/deploy/01_init_cluster.sh`**:
```bash
#!/bin/bash
# Шаг 1: Первичная настройка K8s кластера Selectel
set -e

echo "=== PlayRU: Init Cluster ==="

# Создаём namespace
kubectl apply -f k8s/namespace.yaml
echo "OK: namespace playru"

# Устанавливаем cert-manager (Let's Encrypt TLS)
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml
kubectl wait --for=condition=available deployment/cert-manager \
  -n cert-manager --timeout=120s
echo "OK: cert-manager installed"

# ClusterIssuer для Let's Encrypt
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@playru.ru
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: nginx
EOF
echo "OK: letsencrypt ClusterIssuer"

# NGINX Ingress Controller
kubectl apply -f \
  https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.2/deploy/static/provider/cloud/deploy.yaml
kubectl wait --for=condition=available deployment/ingress-nginx-controller \
  -n ingress-nginx --timeout=180s
echo "OK: nginx ingress"

echo ""
echo "Cluster ready. Next: run 02_create_secrets.sh"
```

**`scripts/deploy/02_create_secrets.sh`**:
```bash
#!/bin/bash
# Шаг 2: Создание секретов в K8s (запускается один раз)
set -e

echo "=== PlayRU: Create Secrets ==="
echo "Введи значения (Enter = пропустить):"

read -p "PostgreSQL password: " PG_PASS
read -p "Nakama DB password: " NK_PASS
read -p "Django secret key (длинная строка): " DJ_SECRET
read -p "VK App Secret: " VK_SECRET
read -p "Yandex Client Secret: " YA_SECRET

kubectl create secret generic playru-secrets \
  --namespace=playru \
  --from-literal=postgres-password="${PG_PASS}" \
  --from-literal=nakama-db-dsn="postgresql://nakama_user:${NK_PASS}@postgres:5432/nakama" \
  --from-literal=django-secret-key="${DJ_SECRET}" \
  --from-literal=django-db-url="postgresql://django_user:${PG_PASS}@postgres:5432/playru" \
  --from-literal=vk-app-secret="${VK_SECRET}" \
  --from-literal=yandex-client-secret="${YA_SECRET}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "OK: Secrets created in namespace playru"

# Создаём imagePullSecret для Selectel Registry
read -p "Selectel Registry user: " REG_USER
read -p "Selectel Registry password: " REG_PASS

kubectl create secret docker-registry selectel-registry \
  --namespace=playru \
  --docker-server=registry.selectel.ru \
  --docker-username="${REG_USER}" \
  --docker-password="${REG_PASS}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "OK: Registry secret created"
echo "Next: run 03_deploy_platform.sh"
```

**`scripts/deploy/03_deploy_platform.sh`**:
```bash
#!/bin/bash
# Шаг 3: Первый деплой платформы
set -e

echo "=== PlayRU: Deploy Platform ==="

# Применяем production overlay
kubectl apply -k k8s/overlays/production

# Ждём готовности PostgreSQL
echo "Waiting for PostgreSQL..."
kubectl rollout status deployment/postgres -n playru --timeout=120s

# Ждём Nakama
echo "Waiting for Nakama..."
kubectl rollout status deployment/nakama -n playru --timeout=180s

# Ждём Django
echo "Waiting for Django..."
kubectl rollout status deployment/django -n playru --timeout=120s

# Применяем Django миграции
echo "Running migrations..."
kubectl exec -n playru deployment/django -- \
  python manage.py migrate --settings=config.settings.production

# Загружаем начальные данные
echo "Loading seed data..."
kubectl exec -n playru deployment/django -- \
  python manage.py seed_games --settings=config.settings.production

echo ""
echo "=== ДЕПЛОЙ ЗАВЕРШЁН ==="
kubectl get pods -n playru
echo ""

# Получаем внешний IP
EXTERNAL_IP=$(kubectl get svc ingress-nginx-controller \
  -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "External IP: $EXTERNAL_IP"
echo "Настрой DNS: api.playru.ru → $EXTERNAL_IP"
```

**`scripts/deploy/04_smoke_test.sh`**:
```bash
#!/bin/bash
# Шаг 4: Проверка что всё работает в production
set -e

DOMAIN="${1:-api.playru.ru}"
echo "=== PlayRU Smoke Test: $DOMAIN ==="

# Health check
curl -sf "https://$DOMAIN/api/v1/platform/health/" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['status'] == 'ok', f'Expected ok: {d}'
print('OK: Platform health:', d.get('version'), '| games:', d.get('games_count'))
"

# Nakama API
curl -sf "https://$DOMAIN/nakama/" > /dev/null && echo "OK: Nakama API accessible"

# Games catalog
curl -sf "https://$DOMAIN/api/v1/games/" | python3 -c "
import sys, json
d = json.load(sys.stdin)
count = d.get('count', 0)
assert count >= 5, f'Expected 5+ games, got {count}'
print(f'OK: Games catalog: {count} games')
"

# Auth test
AUTH=$(curl -sf -X POST "https://$DOMAIN/nakama/v2/account/authenticate/device?create=true" \
  -u "playru-server-key:" -H "Content-Type: application/json" \
  -d '{"id":"smoke-test-device"}' | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

curl -sf -X POST "https://$DOMAIN/nakama/v2/rpc/platform%2Fhealth" \
  -H "Authorization: Bearer $AUTH" -d '{}' > /dev/null && echo "OK: Nakama RPC via HTTPS"

echo ""
echo "✅ Все smoke тесты прошли. Платформа живая: https://$DOMAIN"
```

### Приёмочные тесты задачи 1:
```bash
for f in \
  scripts/deploy/01_init_cluster.sh \
  scripts/deploy/02_create_secrets.sh \
  scripts/deploy/03_deploy_platform.sh \
  scripts/deploy/04_smoke_test.sh; do
  test -f "$f" && echo "OK: $f" || echo "FAIL: $f"
done

chmod +x scripts/deploy/*.sh && echo "OK: scripts executable"
grep -q "cert-manager" scripts/deploy/01_init_cluster.sh && echo "OK: TLS setup"
grep -q "imagePullSecret\|docker-registry" scripts/deploy/02_create_secrets.sh && echo "OK: registry secret"
grep -q "seed_games" scripts/deploy/03_deploy_platform.sh && echo "OK: seed on deploy"
grep -q "smoke" scripts/deploy/04_smoke_test.sh && echo "OK: smoke test script"
```

---

## ЗАДАЧА 2 — Prometheus + Grafana мониторинг

Создай `k8s/monitoring/`:

**`k8s/monitoring/prometheus-config.yaml`**:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-config
  namespace: playru
data:
  prometheus.yml: |
    global:
      scrape_interval: 15s
      evaluation_interval: 15s

    scrape_configs:
      - job_name: 'django'
        static_configs:
          - targets: ['django:8000']
        metrics_path: '/metrics'

      - job_name: 'nakama'
        static_configs:
          - targets: ['nakama:7350']
        metrics_path: '/metrics'

      - job_name: 'postgres'
        static_configs:
          - targets: ['postgres-exporter:9187']

    alerting:
      alertmanagers:
        - static_configs:
            - targets: []

    rule_files:
      - /etc/prometheus/alerts.yml
  
  alerts.yml: |
    groups:
    - name: playru
      rules:
      - alert: DjangoDown
        expr: up{job="django"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Django API is down"
      
      - alert: NakamaDown
        expr: up{job="nakama"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Nakama game server is down"
      
      - alert: HighMemoryUsage
        expr: container_memory_usage_bytes > 800000000
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High memory usage detected"
```

**`k8s/monitoring/prometheus-deployment.yaml`**:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus
  namespace: playru
spec:
  replicas: 1
  selector:
    matchLabels:
      app: prometheus
  template:
    metadata:
      labels:
        app: prometheus
    spec:
      containers:
      - name: prometheus
        image: prom/prometheus:v2.47.0
        ports:
        - containerPort: 9090
        args:
          - "--config.file=/etc/prometheus/prometheus.yml"
          - "--storage.tsdb.retention.time=30d"
          - "--web.enable-lifecycle"
        volumeMounts:
        - name: config
          mountPath: /etc/prometheus
        - name: storage
          mountPath: /prometheus
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"
      volumes:
      - name: config
        configMap:
          name: prometheus-config
      - name: storage
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: prometheus
  namespace: playru
spec:
  selector:
    app: prometheus
  ports:
  - port: 9090
    targetPort: 9090
  type: ClusterIP
```

**`k8s/monitoring/grafana-deployment.yaml`**:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  namespace: playru
spec:
  replicas: 1
  selector:
    matchLabels:
      app: grafana
  template:
    metadata:
      labels:
        app: grafana
    spec:
      containers:
      - name: grafana
        image: grafana/grafana:10.1.0
        ports:
        - containerPort: 3000
        env:
        - name: GF_SECURITY_ADMIN_PASSWORD
          valueFrom:
            secretKeyRef:
              name: playru-secrets
              key: grafana-password
        - name: GF_SERVER_ROOT_URL
          value: "https://monitor.playru.ru"
        - name: GF_INSTALL_PLUGINS
          value: "grafana-piechart-panel"
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "256Mi"
            cpu: "200m"
---
apiVersion: v1
kind: Service
metadata:
  name: grafana
  namespace: playru
spec:
  selector:
    app: grafana
  ports:
  - port: 3000
    targetPort: 3000
  type: ClusterIP
```

Добавь в `k8s/django/ingress.yaml` route для мониторинга:
```yaml
  - host: monitor.playru.ru
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: grafana
            port:
              number: 3000
```

Добавь в `backend/requirements.txt`:
```
django-prometheus>=2.3
```

Добавь в `backend/config/settings/base.py`:
```python
INSTALLED_APPS += ['django_prometheus']

MIDDLEWARE = ['django_prometheus.middleware.PrometheusBeforeMiddleware'] + \
             MIDDLEWARE + \
             ['django_prometheus.middleware.PrometheusAfterMiddleware']
```

Добавь в `backend/config/urls.py`:
```python
urlpatterns += [
    path('', include('django_prometheus.urls')),
]
```

### Приёмочные тесты задачи 2:
```bash
for f in \
  k8s/monitoring/prometheus-config.yaml \
  k8s/monitoring/prometheus-deployment.yaml \
  k8s/monitoring/grafana-deployment.yaml; do
  test -f "$f" && echo "OK: $f" || echo "FAIL: $f"
done

python3 -c "
import yaml
for f in [
  'k8s/monitoring/prometheus-config.yaml',
  'k8s/monitoring/prometheus-deployment.yaml',
  'k8s/monitoring/grafana-deployment.yaml',
]:
    with open(f) as fp: yaml.safe_load(fp)
    print(f'OK: {f} valid')
"

grep -q "DjangoDown" k8s/monitoring/prometheus-config.yaml && echo "OK: Django alert"
grep -q "NakamaDown" k8s/monitoring/prometheus-config.yaml && echo "OK: Nakama alert"
grep -q "django-prometheus" backend/requirements.txt && echo "OK: prometheus lib"
grep -q "django_prometheus" backend/config/settings/base.py && echo "OK: prometheus middleware"
```

---

## ЗАДАЧА 3 — Nakama: рейтинговая система и достижения

Создай `nakama/modules/achievements.lua`:

```lua
-- PlayRU: Achievement System
local nk = require("nakama")

local ACHIEVEMENTS = {
    first_game = {
        id = "first_game",
        name = "Первая игра",
        description = "Сыграй в первую игру",
        reward_coins = 50,
        icon = "🎮"
    },
    parkour_master = {
        id = "parkour_master",
        name = "Мастер паркура",
        description = "Пробеги паркур за менее чем 20 секунд",
        reward_coins = 100,
        icon = "🏃"
    },
    arena_warrior = {
        id = "arena_warrior",
        name = "Воин арены",
        description = "Набери 10 убийств в одном матче",
        reward_coins = 100,
        icon = "⚔️"
    },
    clicker_addict = {
        id = "clicker_addict",
        name = "Кликер-маньяк",
        description = "Сделай 10,000 кликов",
        reward_coins = 75,
        icon = "👆"
    },
    survivor = {
        id = "survivor",
        name = "Выживший",
        description = "Продержись 10 дней на острове",
        reward_coins = 150,
        icon = "🏝️"
    },
    defender = {
        id = "defender",
        name = "Защитник",
        description = "Пройди все 10 волн Tower Defense",
        reward_coins = 150,
        icon = "🏰"
    },
    rich_player = {
        id = "rich_player",
        name = "Богатей",
        description = "Накопи 1000 PlayCoin",
        reward_coins = 0,
        icon = "💰"
    },
}

-- Проверить и выдать достижение
local function unlock_achievement(user_id, achievement_id)
    local achievement = ACHIEVEMENTS[achievement_id]
    if not achievement then return false end

    -- Проверяем не выдано ли уже
    local objects = nk.storage_read({
        {collection = "achievements", key = achievement_id, user_id = user_id}
    })
    if #objects > 0 then return false end

    -- Записываем
    nk.storage_write({
        {
            collection = "achievements",
            key = achievement_id,
            user_id = user_id,
            value = nk.json_encode({
                unlocked_at = nk.time(),
                achievement_id = achievement_id
            }),
            permission_read = 1,
            permission_write = 0
        }
    })

    -- Награда
    if achievement.reward_coins > 0 then
        nk.wallet_update(user_id, {playcoin = achievement.reward_coins},
            {source = "achievement", id = achievement_id}, true)
    end

    -- Уведомление
    nk.notifications_send({
        {
            user_id = user_id,
            subject = achievement.icon .. " Достижение: " .. achievement.name,
            content = {
                description = achievement.description,
                coins = achievement.reward_coins,
                achievement_id = achievement_id
            },
            code = 3,
            sender_id = "00000000-0000-0000-0000-000000000000",
            persistent = true
        }
    })

    nk.logger_info("Achievement unlocked: " .. user_id .. " / " .. achievement_id)
    return true
end

-- RPC: Получить все достижения игрока
local function get_achievements(context, payload)
    local user_id = context.user_id
    local result = {}

    for id, achievement in pairs(ACHIEVEMENTS) do
        local objects = nk.storage_read({
            {collection = "achievements", key = id, user_id = user_id}
        })
        table.insert(result, {
            id = id,
            name = achievement.name,
            description = achievement.description,
            icon = achievement.icon,
            reward_coins = achievement.reward_coins,
            unlocked = #objects > 0,
            unlocked_at = #objects > 0 and nk.json_decode(objects[1].value).unlocked_at or nil
        })
    end

    local unlocked_count = 0
    for _, a in ipairs(result) do
        if a.unlocked then unlocked_count = unlocked_count + 1 end
    end

    return nk.json_encode({
        achievements = result,
        total = #result,
        unlocked = unlocked_count
    })
end

-- RPC: Разблокировать достижение (вызывается из игровой логики)
local function trigger_achievement(context, payload)
    local data = nk.json_decode(payload)
    if not data or not data.achievement_id then
        error("Missing achievement_id")
    end

    local unlocked = unlock_achievement(context.user_id, data.achievement_id)
    local achievement = ACHIEVEMENTS[data.achievement_id]

    return nk.json_encode({
        success = true,
        already_had = not unlocked,
        achievement = achievement,
        coins_earned = (unlocked and achievement and achievement.reward_coins) or 0
    })
end

nk.register_rpc(get_achievements, "platform/achievements")
nk.register_rpc(trigger_achievement, "platform/achievements/unlock")

-- Экспортируем для других модулей
return {unlock = unlock_achievement}
```

Добавь в `nakama/modules/init.lua`:
```lua
local achievements = require("achievements")
```

Обнови `nakama/modules/games/parkour.lua` — добавь проверку достижения:
```lua
-- В конце parkour_submit_score, после wallet_update:
if time_ms < 20000 then  -- быстрее 20 секунд
    local ach = require("achievements")
    ach.unlock(user_id, "parkour_master")
end
-- Всегда проверяем first_game:
local ach = require("achievements")
ach.unlock(user_id, "first_game")
```

### Приёмочные тесты задачи 3:
```bash
docker compose up -d && sleep 20

AUTH=$(curl -sf -X POST \
  "http://localhost:7350/v2/account/authenticate/device?create=true&username=ach_$$" \
  -u "playru-server-key:" -H "Content-Type: application/json" \
  -d '{"id":"ach-test-'$$'"}' | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

# Получить список достижений:
curl -sf -X POST "http://localhost:7350/v2/rpc/platform%2Fachievements" \
  -H "Authorization: Bearer $AUTH" -d '{}' | python3 -c "
import sys, json
d = json.load(sys.stdin)
payload = json.loads(d.get('payload','{}').strip('\"').replace('\\\\\"','\"'))
total = payload.get('total', 0)
assert total >= 5, f'Expected 5+ achievements: {total}'
print(f'OK: {total} achievements defined, {payload.get(\"unlocked\",0)} unlocked')
"

# Разблокировать достижение:
curl -sf -X POST "http://localhost:7350/v2/rpc/platform%2Fachievements%2Funlock" \
  -H "Authorization: Bearer $AUTH" -H "Content-Type: application/json" \
  -d '{"achievement_id": "first_game"}' | python3 -c "
import sys, json
d = json.load(sys.stdin)
payload = json.loads(d.get('payload','{}').strip('\"').replace('\\\\\"','\"'))
assert payload.get('success') == True
coins = payload.get('coins_earned', 0)
print(f'OK: Achievement unlocked, earned {coins} coins')
"

# Повторная разблокировка — already_had:
curl -sf -X POST "http://localhost:7350/v2/rpc/platform%2Fachievements%2Funlock" \
  -H "Authorization: Bearer $AUTH" -H "Content-Type: application/json" \
  -d '{"achievement_id": "first_game"}' | python3 -c "
import sys, json
d = json.load(sys.stdin)
payload = json.loads(d.get('payload','{}').strip('\"').replace('\\\\\"','\"'))
assert payload.get('already_had') == True
print('OK: Duplicate achievement correctly marked as already_had')
"

docker compose down
```

---

## ЗАДАЧА 4 — Django: публичный дашборд для питч-дека

Создай `backend/apps/platform/views_dashboard.py`:

```python
"""
Публичный дашборд PlayRU — для питч-дека Яндексу/VK.
URL: /dashboard/  — красивая страница с метриками в реальном времени.
"""
from django.http import JsonResponse
from django.views import View
from django.utils import timezone
from datetime import timedelta
from apps.games.models import Game
from apps.platform.models import UserProfile, GameSession, PlatformStats


class PublicMetricsView(View):
    """
    GET /api/v1/public/metrics/
    Возвращает ключевые метрики платформы — для питч-дека и публичного дашборда.
    """

    def get(self, request):
        now = timezone.now()
        last_24h = now - timedelta(hours=24)
        last_7d = now - timedelta(days=7)
        last_30d = now - timedelta(days=30)

        # Пользователи
        total_users = UserProfile.objects.count()
        dau = UserProfile.objects.filter(last_seen__gte=last_24h).count()
        wau = UserProfile.objects.filter(last_seen__gte=last_7d).count()
        mau = UserProfile.objects.filter(last_seen__gte=last_30d).count()
        new_today = UserProfile.objects.filter(
            created_at__gte=now.replace(hour=0, minute=0, second=0)
        ).count()

        # Сессии
        sessions_24h = GameSession.objects.filter(started_at__gte=last_24h).count()
        sessions_total = GameSession.objects.count()
        avg_session_qs = GameSession.objects.filter(
            started_at__gte=last_7d,
            duration_seconds__gt=0
        )
        avg_session = 0
        if avg_session_qs.exists():
            total_dur = sum(s.duration_seconds for s in avg_session_qs)
            avg_session = round(total_dur / avg_session_qs.count() / 60, 1)

        # Игры
        games_count = Game.objects.filter(status='published').count()
        top_games = list(
            Game.objects.filter(status='published')
            .order_by('-play_count')[:5]
            .values('title', 'play_count', 'slug')
        )

        # Провайдеры авторизации
        auth_breakdown = {}
        for provider in ['vk', 'yandex', 'guest']:
            auth_breakdown[provider] = UserProfile.objects.filter(
                auth_provider=provider
            ).count()

        return JsonResponse({
            'platform': 'PlayRU',
            'updated_at': now.isoformat(),
            'users': {
                'total': total_users,
                'dau': dau,
                'wau': wau,
                'mau': mau,
                'new_today': new_today,
                'retention_d1': round(dau / max(total_users, 1) * 100, 1),
            },
            'sessions': {
                'last_24h': sessions_24h,
                'total': sessions_total,
                'avg_duration_minutes': avg_session,
            },
            'games': {
                'published': games_count,
                'top': top_games,
            },
            'auth': auth_breakdown,
            'valuation_signal': {
                'mau': mau,
                'est_value_rub': mau * 3000,
                'note': 'Оценка: ~3000 руб/MAU для российских игровых платформ'
            }
        })
```

Добавь URL в `backend/config/urls.py`:
```python
from apps.platform.views_dashboard import PublicMetricsView

urlpatterns += [
    path('api/v1/public/metrics/', PublicMetricsView.as_view()),
]
```

### Приёмочные тесты задачи 4:
```bash
cd backend
python manage.py check && echo "OK: Django check"

python manage.py runserver &
sleep 3

curl -sf http://localhost:8000/api/v1/public/metrics/ | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['platform'] == 'PlayRU'
assert 'users' in d
assert 'mau' in d['users']
assert 'sessions' in d
assert 'games' in d
assert 'valuation_signal' in d
print('OK: Public metrics endpoint works')
print('  MAU:', d['users']['mau'])
print('  Games:', d['games']['published'])
print('  Est value:', d['valuation_signal']['est_value_rub'], 'rub')
"

kill %1
```

---

## ✅ ФИНАЛЬНАЯ ПРИЁМКА НЕДЕЛИ 3

```bash
docker compose up -d && sleep 20
cd backend && python manage.py runserver & && sleep 3

AUTH=$(curl -sf -X POST "http://localhost:7350/v2/account/authenticate/device?create=true" \
  -u "playru-server-key:" -H "Content-Type: application/json" \
  -d '{"id":"final-w3-'$$'"}' | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

echo "--- 15 Nakama RPCs ---"
for rpc in \
  "platform%2Fhealth" "platform%2Fleaderboard" \
  "platform%2Fnotifications" "platform%2Fachievements" \
  "platform%2Fachievements%2Funlock" \
  "economy%2Fwallet" "economy%2Fdaily_reward" \
  "auth%2Fvk" "auth%2Fyandex" \
  "games%2Fparkour%2Fsubmit_score" \
  "games%2Farena%2Fsubmit_result" \
  "games%2Fclicker%2Fsync" \
  "games%2Fracing%2Fsubmit_result" \
  "games%2Ftower_defense%2Fsubmit_result" \
  "games%2Fisland_survival%2Fsubmit_result"; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "http://localhost:7350/v2/rpc/$rpc" \
    -H "Authorization: Bearer $AUTH" -d '{}')
  [ "$STATUS" != "404" ] && echo "OK: $rpc" || echo "FAIL: $rpc"
done

echo "--- Django ---"
for url in \
  "http://localhost:8000/api/v1/platform/health/" \
  "http://localhost:8000/api/v1/games/" \
  "http://localhost:8000/api/v1/public/metrics/"; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$url")
  [ "$STATUS" = "200" ] && echo "OK: $url" || echo "FAIL: $url"
done

echo "--- K8s файлы ---"
python3 -c "
import yaml, os
count = 0
for root, dirs, files in os.walk('k8s'):
    for f in files:
        if f.endswith('.yaml') and 'secrets' not in f:
            with open(os.path.join(root, f)) as fp: yaml.safe_load(fp)
            count += 1
print(f'OK: {count} YAML files valid')
"

echo "--- Деплой скрипты ---"
for f in scripts/deploy/0{1,2,3,4}_*.sh; do
  test -f "$f" && echo "OK: $f" || echo "FAIL: $f"
done

pytest tests/ -v --tb=short
kill %1 2>/dev/null
docker compose down

echo ""
echo "================================================"
echo "  НЕДЕЛЯ 3 ВЫПОЛНЕНА"
echo "  15 Nakama RPC, мониторинг, достижения"
echo "  Публичные метрики для питч-дека"
echo "  Деплой скрипты для Selectel"
echo "================================================"
```

> **Агент останавливается здесь и ждёт команды.**
