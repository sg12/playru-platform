# AGENT 1 — playru-platform — НЕДЕЛЯ 2
## Production деплой: Selectel K8s + ArgoCD + CI/CD

> **Инструкция агенту:**
> Продолжаем в репозитории playru-platform.
> Все предыдущие волны завершены: Nakama, Django, K8s манифесты готовы.
> Цель недели: платформа работает в интернете на реальных серверах.
> Выполняй задачи строго по порядку.
> После каждой задачи запускай приёмочные тесты — все должны быть зелёные.
> Останови работу только когда ФИНАЛЬНАЯ ПРИЁМКА пройдена полностью.

---

## ЗАДАЧА 1 — ArgoCD Application манифесты

Создай структуру GitOps репозитория внутри k8s/:

```
k8s/
├── argocd/
│   ├── install-argocd.sh          # Скрипт установки ArgoCD в кластер
│   ├── playru-app.yaml            # ArgoCD Application для всей платформы
│   ├── playru-platform-app.yaml   # ArgoCD App для бэкенда
│   └── playru-client-app.yaml     # ArgoCD App для статики (future)
└── overlays/
    ├── development/
    │   └── kustomization.yaml
    └── production/
        └── kustomization.yaml
```

**`k8s/argocd/install-argocd.sh`**:
```bash
#!/bin/bash
# Установка ArgoCD в K8s кластер Selectel
set -e

echo "=== Installing ArgoCD ==="

# Создаём namespace
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# Устанавливаем ArgoCD
kubectl apply -n argocd -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Ждём готовности
echo "Waiting for ArgoCD pods..."
kubectl wait --for=condition=available deployment/argocd-server \
  -n argocd --timeout=300s

# Получаем начальный пароль
echo "ArgoCD admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
echo ""

# Port-forward для первого входа
echo "Access ArgoCD UI:"
echo "  kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "  https://localhost:8080  (admin / пароль выше)"
```

**`k8s/argocd/playru-platform-app.yaml`**:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: playru-platform
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/YOUR_ORG/playru-platform.git
    targetRevision: HEAD
    path: k8s/overlays/production
  destination:
    server: https://kubernetes.default.svc
    namespace: playru
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
      allowEmpty: false
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

**`k8s/overlays/production/kustomization.yaml`**:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: playru

resources:
  - ../../namespace.yaml
  - ../../postgres/deployment.yaml
  - ../../postgres/service.yaml
  - ../../postgres/pvc.yaml
  - ../../nakama/deployment.yaml
  - ../../nakama/service.yaml
  - ../../nakama/configmap.yaml
  - ../../django/deployment.yaml
  - ../../django/service.yaml
  - ../../django/ingress.yaml

images:
  - name: playru-backend
    newName: registry.selectel.ru/playru/backend
    newTag: latest

patches:
  - patch: |-
      - op: replace
        path: /spec/replicas
        value: 2
    target:
      kind: Deployment
      name: django
  - patch: |-
      - op: replace
        path: /spec/replicas
        value: 2
    target:
      kind: Deployment
      name: nakama
```

**`k8s/overlays/development/kustomization.yaml`**:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: playru-dev

resources:
  - ../../namespace.yaml
  - ../../postgres/deployment.yaml
  - ../../postgres/service.yaml
  - ../../postgres/pvc.yaml
  - ../../nakama/deployment.yaml
  - ../../nakama/service.yaml
  - ../../django/deployment.yaml
  - ../../django/service.yaml

patches:
  - patch: |-
      - op: replace
        path: /spec/replicas
        value: 1
    target:
      kind: Deployment
  - patch: |-
      - op: replace
        path: /spec/resources/requests/memory
        value: "128Mi"
    target:
      kind: Deployment
      name: nakama
```

### Приёмочные тесты задачи 1:
```bash
for f in \
  k8s/argocd/install-argocd.sh \
  k8s/argocd/playru-platform-app.yaml \
  k8s/overlays/production/kustomization.yaml \
  k8s/overlays/development/kustomization.yaml; do
  test -f "$f" && echo "OK: $f" || echo "FAIL: $f missing"
done

python3 -c "
import yaml
files = [
  'k8s/argocd/playru-platform-app.yaml',
  'k8s/overlays/production/kustomization.yaml',
  'k8s/overlays/development/kustomization.yaml',
]
for f in files:
    with open(f) as fp: yaml.safe_load(fp)
    print(f'OK: {f} valid YAML')
"

grep -q "automated" k8s/argocd/playru-platform-app.yaml && echo "OK: auto-sync enabled"
grep -q "selfHeal: true" k8s/argocd/playru-platform-app.yaml && echo "OK: selfHeal enabled"
grep -q "prune: true" k8s/argocd/playru-platform-app.yaml && echo "OK: prune enabled"
grep -q "registry.selectel.ru" k8s/overlays/production/kustomization.yaml && echo "OK: Selectel registry"

# kustomize синтаксис (если установлен):
if command -v kustomize &>/dev/null; then
  kustomize build k8s/overlays/development > /dev/null && echo "OK: kustomize build dev"
fi
```

---

## ЗАДАЧА 2 — GitHub Actions CI/CD pipeline

Создай `.github/workflows/`:

**`.github/workflows/ci.yml`** — тесты при каждом push:
```yaml
name: CI

on:
  push:
    branches: [ main, develop ]
  pull_request:
    branches: [ main ]

jobs:
  test:
    runs-on: ubuntu-latest
    
    services:
      postgres:
        image: postgres:15-alpine
        env:
          POSTGRES_PASSWORD: testpass
          POSTGRES_DB: playru_test
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
        ports:
          - 5432:5432

    steps:
    - uses: actions/checkout@v4
    
    - name: Set up Python 3.11
      uses: actions/setup-python@v4
      with:
        python-version: '3.11'
        cache: 'pip'
        cache-dependency-path: backend/requirements.txt
    
    - name: Install dependencies
      run: |
        cd backend
        pip install -r requirements.txt
        pip install pytest-cov
    
    - name: Run Django tests
      env:
        DJANGO_SETTINGS_MODULE: config.settings.development
        POSTGRES_HOST: localhost
        POSTGRES_PORT: 5432
        POSTGRES_DB: playru_test
        POSTGRES_USER: postgres
        POSTGRES_PASSWORD: testpass
        DJANGO_SECRET_KEY: ci-test-secret-key-not-for-production
        DJANGO_DEBUG: "True"
      run: |
        cd backend
        python manage.py migrate
        pytest tests/ -v --tb=short --cov=apps --cov-report=term-missing
    
    - name: Check Django configuration
      run: |
        cd backend
        python manage.py check --deploy --settings=config.settings.production \
          || echo "Deploy check warnings (expected in CI)"

  lint:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4
    - uses: actions/setup-python@v4
      with:
        python-version: '3.11'
    - name: Lint with flake8
      run: |
        pip install flake8
        cd backend
        flake8 apps/ --max-line-length=120 --ignore=E501,W503 || true
    
    - name: Validate K8s YAML
      run: |
        pip install pyyaml
        python3 -c "
import yaml, os, sys
errors = []
for root, dirs, files in os.walk('k8s'):
    dirs[:] = [d for d in dirs if d != '.git']
    for f in files:
        if f.endswith('.yaml') and 'secrets' not in f:
            path = os.path.join(root, f)
            try:
                with open(path) as fp: yaml.safe_load(fp)
            except Exception as e:
                errors.append(f'{path}: {e}')
if errors:
    for e in errors: print('FAIL:', e)
    sys.exit(1)
print(f'OK: All YAML valid')
"
```

**`.github/workflows/deploy.yml`** — деплой при merge в main:
```yaml
name: Deploy to Production

on:
  push:
    branches: [ main ]
  workflow_dispatch:
    inputs:
      force_deploy:
        description: 'Force deploy even if tests fail'
        required: false
        default: 'false'

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    needs: []
    
    steps:
    - uses: actions/checkout@v4
    
    - name: Set up Docker Buildx
      uses: docker/setup-buildx-action@v3
    
    - name: Login to Selectel Registry
      uses: docker/login-action@v3
      with:
        registry: registry.selectel.ru
        username: ${{ secrets.SELECTEL_REGISTRY_USER }}
        password: ${{ secrets.SELECTEL_REGISTRY_PASSWORD }}
    
    - name: Build and push Django image
      uses: docker/build-push-action@v5
      with:
        context: ./backend
        push: true
        tags: |
          registry.selectel.ru/playru/backend:latest
          registry.selectel.ru/playru/backend:${{ github.sha }}
        cache-from: type=gha
        cache-to: type=gha,mode=max
    
  deploy:
    runs-on: ubuntu-latest
    needs: build-and-push
    environment: production
    
    steps:
    - uses: actions/checkout@v4
    
    - name: Set up kubectl
      uses: azure/setup-kubectl@v3
    
    - name: Configure kubectl for Selectel
      run: |
        mkdir -p ~/.kube
        echo "${{ secrets.KUBECONFIG_BASE64 }}" | base64 -d > ~/.kube/config
        chmod 600 ~/.kube/config
    
    - name: Update image tag in kustomization
      run: |
        cd k8s/overlays/production
        sed -i "s/newTag: latest/newTag: ${{ github.sha }}/" kustomization.yaml
    
    - name: Apply K8s manifests
      run: |
        kubectl apply -k k8s/overlays/production
        kubectl rollout status deployment/django -n playru --timeout=300s
        kubectl rollout status deployment/nakama -n playru --timeout=300s
    
    - name: Run smoke tests
      run: |
        DJANGO_URL=$(kubectl get ingress -n playru -o jsonpath='{.items[0].spec.rules[0].host}')
        sleep 30
        curl -sf "https://$DJANGO_URL/api/v1/platform/health/" | \
          python3 -c "import sys,json; d=json.load(sys.stdin); assert d['status']=='ok'; print('OK: Production health check')"
    
    - name: Notify on failure
      if: failure()
      run: echo "Deploy failed - check logs"
```

### Приёмочные тесты задачи 2:
```bash
for f in \
  .github/workflows/ci.yml \
  .github/workflows/deploy.yml; do
  test -f "$f" && echo "OK: $f" || echo "FAIL: $f missing"
done

python3 -c "
import yaml
for f in ['.github/workflows/ci.yml', '.github/workflows/deploy.yml']:
    with open(f) as fp: yaml.safe_load(fp)
    print(f'OK: {f} valid YAML')
"

grep -q "pytest" .github/workflows/ci.yml && echo "OK: pytest in CI"
grep -q "postgres:" .github/workflows/ci.yml && echo "OK: postgres service in CI"
grep -q "registry.selectel.ru" .github/workflows/deploy.yml && echo "OK: Selectel registry"
grep -q "rollout status" .github/workflows/deploy.yml && echo "OK: rollout health check"
grep -q "smoke tests" .github/workflows/deploy.yml && echo "OK: smoke tests after deploy"
grep -q "KUBECONFIG_BASE64" .github/workflows/deploy.yml && echo "OK: kubeconfig secret"
```

---

## ЗАДАЧА 3 — Nakama Lua: система уведомлений и хуки

Создай `nakama/modules/notifications.lua`:

```lua
-- PlayRU: Notifications — внутренние уведомления игрокам
local nk = require("nakama")

local NOTIFICATION_CODES = {
    WELCOME         = 1,
    DAILY_REWARD    = 2,
    ACHIEVEMENT     = 3,
    FRIEND_JOINED   = 4,
    LEADERBOARD_TOP = 5,
    COINS_RECEIVED  = 6,
}

-- Отправить уведомление игроку
local function send_notification(user_id, code, subject, content, sender_id)
    sender_id = sender_id or "00000000-0000-0000-0000-000000000000"
    nk.notifications_send({
        {
            user_id = user_id,
            subject = subject,
            content = content,
            code = code,
            sender_id = sender_id,
            persistent = true
        }
    })
end

-- RPC: Получить непрочитанные уведомления
local function get_notifications(context, payload)
    local data = nk.json_decode(payload or "{}")
    local limit = (data and data.limit) or 20

    local notifications, cursor = nk.notifications_list(context.user_id, limit, nil)

    local result = {}
    for _, n in ipairs(notifications) do
        table.insert(result, {
            id = n.id,
            subject = n.subject,
            content = n.content,
            code = n.code,
            create_time = n.create_time,
        })
    end

    return nk.json_encode({
        notifications = result,
        count = #result
    })
end

-- RPC: Отметить уведомления прочитанными
local function mark_read(context, payload)
    local data = nk.json_decode(payload)
    if not data or not data.ids then
        error("Missing notification ids")
    end
    nk.notifications_delete(context.user_id, data.ids)
    return nk.json_encode({success = true, deleted = #data.ids})
end

-- Хук: Welcome уведомление при регистрации
local function on_account_created_notify(context, logger, nk_hook, data)
    send_notification(
        data.user_id,
        NOTIFICATION_CODES.WELCOME,
        "Добро пожаловать в PlayRU! 🎮",
        {message = "Вам начислено 100 PlayCoin. Удачной игры!", coins = 100},
        nil
    )
    logger:info("Welcome notification sent to: " .. data.user_id)
end

nk.register_rpc(get_notifications, "platform/notifications")
nk.register_rpc(mark_read, "platform/notifications/read")

-- Экспортируем функцию для использования в других модулях
return {
    send = send_notification,
    CODES = NOTIFICATION_CODES
}
```

Обнови `nakama/modules/init.lua` — теперь notifications доступен глобально:
```lua
local notifications = require("notifications")

-- Хук на создание аккаунта (объединяем wallet + notification)
nk.register_after(function(context, logger, nk_hook, out, in_data)
    local user_id = out.session.user_id
    -- Welcome bonus
    nk_hook.wallet_update(user_id, {playcoin = 100}, {source = "welcome"}, true)
    -- Welcome notification
    notifications.send(
        user_id,
        notifications.CODES.WELCOME,
        "Добро пожаловать в PlayRU! 🎮",
        {message = "Вам начислено 100 стартовых PlayCoin!", coins = 100},
        nil
    )
    logger:info("New user setup complete: " .. user_id)
end, "AuthenticateDevice")
```

### Приёмочные тесты задачи 3:
```bash
docker compose up -d
sleep 20

AUTH=$(curl -sf -X POST \
  "http://localhost:7350/v2/account/authenticate/device?create=true&username=notif_$$" \
  -u "playru-server-key:" -H "Content-Type: application/json" \
  -d '{"id":"notif-test-'$$'"}' | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

# Получить уведомления (должно быть welcome):
curl -sf -X POST "http://localhost:7350/v2/rpc/platform%2Fnotifications" \
  -H "Authorization: Bearer $AUTH" -d '{}' | python3 -c "
import sys, json
d = json.load(sys.stdin)
payload = json.loads(d.get('payload','{}').strip('\"').replace('\\\\\"','\"'))
count = payload.get('count', 0)
print(f'OK: Notifications endpoint works, {count} notifications')
"

# RPC mark_read существует:
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  "http://localhost:7350/v2/rpc/platform%2Fnotifications%2Fread" \
  -H "Authorization: Bearer $AUTH" \
  -d '{"ids":[]}')
[ "$STATUS" != "404" ] && echo "OK: mark_read RPC exists" || echo "FAIL: mark_read not found"

docker compose down
```

---

## ЗАДАЧА 4 — Django: игровые сессии и аналитика

Добавь в `backend/apps/platform/models.py` модели аналитики:

```python
class GameSession(models.Model):
    """Запись об игровой сессии — для аналитики и продажи платформы."""
    
    session_id = models.UUIDField(default=uuid.uuid4, unique=True, db_index=True)
    nakama_user_id = models.CharField(max_length=100, db_index=True)
    game = models.ForeignKey('games.Game', on_delete=models.SET_NULL,
                              null=True, related_name='sessions')
    
    started_at = models.DateTimeField(auto_now_add=True)
    ended_at = models.DateTimeField(null=True, blank=True)
    duration_seconds = models.PositiveIntegerField(default=0)
    
    score = models.PositiveBigIntegerField(default=0)
    completed = models.BooleanField(default=False)
    
    # Для продажи: метаданные устройства
    platform = models.CharField(max_length=20, default='android',
                                  choices=[('android','Android'),('ios','iOS'),('web','Web')])
    
    class Meta:
        verbose_name = 'Игровая сессия'
        ordering = ['-started_at']
        indexes = [
            models.Index(fields=['nakama_user_id', 'started_at']),
            models.Index(fields=['game', 'started_at']),
        ]


class PlatformStats(models.Model):
    """Агрегированная статистика за день — для питч-дека Яндексу."""
    
    date = models.DateField(unique=True, db_index=True)
    dau = models.PositiveIntegerField(default=0, verbose_name='DAU')
    new_users = models.PositiveIntegerField(default=0)
    total_sessions = models.PositiveIntegerField(default=0)
    total_playtime_hours = models.FloatField(default=0.0)
    revenue_rub = models.DecimalField(max_digits=12, decimal_places=2, default=0)
    
    class Meta:
        verbose_name = 'Статистика платформы'
        ordering = ['-date']
```

Добавь endpoint:
- `POST /api/v1/sessions/start/` — начало сессии
- `POST /api/v1/sessions/<session_id>/end/` — конец сессии с результатом
- `GET /api/v1/stats/summary/` — сводка для дашборда (DAU, MAU, total sessions)

Зарегистрируй в Admin с графиками по дням.

### Приёмочные тесты задачи 4:
```bash
cd backend
python manage.py makemigrations platform
python manage.py migrate && echo "OK: Migrations applied"
python manage.py check && echo "OK: Django check"

python manage.py runserver &
sleep 3

# Start session:
SESSION=$(curl -sf -X POST http://localhost:8000/api/v1/sessions/start/ \
  -H "Content-Type: application/json" \
  -d '{"nakama_user_id":"test-user-123","game_slug":"parkour-simulator","platform":"android"}' \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['session_id'])")
echo "OK: Session started: $SESSION"

# End session:
curl -sf -X POST "http://localhost:8000/api/v1/sessions/$SESSION/end/" \
  -H "Content-Type: application/json" \
  -d '{"score": 1500, "completed": true, "duration_seconds": 120}' \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d.get('duration_seconds') == 120
print('OK: Session ended, duration=', d['duration_seconds'], 's')
"

# Stats summary:
curl -sf http://localhost:8000/api/v1/stats/summary/ | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert 'total_sessions' in d
print('OK: Stats summary:', d)
"

pytest tests/test_platform.py -v
kill %1
docker compose down
```

---

## ✅ ФИНАЛЬНАЯ ПРИЁМКА НЕДЕЛИ 2

```bash
docker compose up -d
sleep 20
cd backend && python manage.py runserver &
sleep 3

echo "=== ФИНАЛЬНАЯ ПРИЁМКА НЕДЕЛИ 2 ==="

AUTH=$(curl -sf -X POST "http://localhost:7350/v2/account/authenticate/device?create=true" \
  -u "playru-server-key:" -H "Content-Type: application/json" \
  -d '{"id":"final-w2-'$$'"}' | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

echo "--- Nakama RPCs (все 14) ---"
for rpc in \
  "auth%2Fvk" "auth%2Fyandex" \
  "economy%2Fwallet" "economy%2Fdaily_reward" "economy%2Fwallet_history" \
  "platform%2Fhealth" "platform%2Fleaderboard" "platform%2Fnotifications" \
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
  "http://localhost:8000/api/v1/stats/summary/"; do
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$url")
    [ "$STATUS" = "200" ] && echo "OK: $url" || echo "FAIL: $url ($STATUS)"
done

echo "--- CI/CD файлы ---"
test -f .github/workflows/ci.yml && echo "OK: ci.yml"
test -f .github/workflows/deploy.yml && echo "OK: deploy.yml"

echo "--- K8s / ArgoCD ---"
python3 -c "
import yaml, os
count = 0
for root, dirs, files in os.walk('k8s'):
    for f in files:
        if f.endswith('.yaml') and 'secrets' not in f:
            with open(os.path.join(root, f)) as fp: yaml.safe_load(fp)
            count += 1
print(f'OK: {count} K8s YAML files valid')
"

echo "--- Все тесты ---"
pytest tests/ -v --tb=short
FAILS=$(pytest tests/ 2>&1 | grep -c "FAILED" || true)
[ "$FAILS" -eq 0 ] && echo "OK: All tests green" || echo "FAIL: $FAILS failed"

kill %1 2>/dev/null
docker compose down

echo ""
echo "================================================"
echo "  НЕДЕЛЯ 2 ВЫПОЛНЕНА"
echo "  ArgoCD: манифесты готовы"
echo "  GitHub Actions: CI + deploy pipeline"
echo "  Уведомления: welcome + daily reward"
echo "  Аналитика: GameSession + PlatformStats"
echo "================================================"
```

> **Агент останавливается здесь и ждёт команды.**
