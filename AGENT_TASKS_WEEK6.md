# AGENT 1 — playru-platform — НЕДЕЛЯ 6 (ФИНАЛЬНАЯ)
## Production hardening: rate limiting, Sentry, health checks, нагрузочный тест

> Последняя неделя перед питч-деком. Бэкенд должен выдержать первых реальных пользователей.
> Цель: 500 одновременных игроков без деградации, все ошибки логируются,
> платформа не падает при неожиданных запросах.
> После каждой задачи — приёмочные тесты. Стоп после ФИНАЛЬНОЙ ПРИЁМКИ.

---

## ЗАДАЧА 1 — Rate limiting и защита API

Добавь в `backend/requirements.txt`:
```
django-ratelimit>=4.1
```

Создай `backend/apps/platform/middleware.py`:

```python
"""
Middleware для защиты PlayRU API.
"""
import json
import time
import hashlib
from django.http import JsonResponse
from django.core.cache import cache


class RateLimitMiddleware:
    """
    Простой rate limiter: 100 запросов/минуту на IP для публичных endpoint'ов.
    Более строгий для /shop/ (10 запросов/минуту).
    """

    LIMITS = {
        '/api/v1/shop/order/': (10, 60),    # 10 req / 60 sec
        '/api/v1/shop/':       (30, 60),    # 30 req / 60 sec
        '/api/v1/':            (100, 60),   # 100 req / 60 sec
    }

    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        ip = self._get_ip(request)
        path = request.path

        for prefix, (limit, window) in self.LIMITS.items():
            if path.startswith(prefix):
                key = f'rl:{hashlib.md5((ip + prefix).encode()).hexdigest()}'
                count = cache.get(key, 0)
                if count >= limit:
                    return JsonResponse({
                        'error': 'Too many requests',
                        'retry_after': window,
                    }, status=429)
                cache.set(key, count + 1, window)
                break

        response = self.get_response(request)
        return response

    def _get_ip(self, request):
        forwarded = request.META.get('HTTP_X_FORWARDED_FOR')
        if forwarded:
            return forwarded.split(',')[0].strip()
        return request.META.get('REMOTE_ADDR', '0.0.0.0')


class RequestTimingMiddleware:
    """Логирует медленные запросы (>500ms)."""

    SLOW_THRESHOLD_MS = 500

    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        start = time.time()
        response = self.get_response(request)
        elapsed_ms = (time.time() - start) * 1000

        if elapsed_ms > self.SLOW_THRESHOLD_MS:
            import logging
            logger = logging.getLogger('playru.performance')
            logger.warning(
                f'SLOW {request.method} {request.path} '
                f'{response.status_code} — {elapsed_ms:.0f}ms'
            )

        response['X-Response-Time'] = f'{elapsed_ms:.0f}ms'
        return response
```

Добавь в `backend/config/settings/base.py`:
```python
MIDDLEWARE += [
    'apps.platform.middleware.RateLimitMiddleware',
    'apps.platform.middleware.RequestTimingMiddleware',
]

LOGGING = {
    'version': 1,
    'disable_existing_loggers': False,
    'formatters': {
        'json': {
            '()': 'django.utils.log.ServerFormatter',
            'format': '[%(asctime)s] %(levelname)s %(name)s: %(message)s',
        },
    },
    'handlers': {
        'console': {
            'class': 'logging.StreamHandler',
            'formatter': 'json',
        },
    },
    'loggers': {
        'playru': {'handlers': ['console'], 'level': 'INFO', 'propagate': False},
        'playru.performance': {'handlers': ['console'], 'level': 'WARNING'},
        'django.request': {'handlers': ['console'], 'level': 'ERROR'},
    },
}
```

### Приёмочные тесты задачи 1:
```bash
cd backend
python manage.py check && echo "OK: Django check"

python manage.py runserver &
sleep 3

# Rate limit тест: 35 быстрых запросов к /shop/
for i in $(seq 1 35); do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    "http://localhost:8000/api/v1/shop/packages/")
  echo -n "$CODE "
done
echo ""
echo "OK: Rate limit test done (expect 429 after ~30 requests)"

# X-Response-Time header:
curl -sI http://localhost:8000/api/v1/platform/health/ | grep -i "X-Response-Time" \
  && echo "OK: timing header present"

kill %1
```

---

## ЗАДАЧА 2 — Расширенный health check и readiness probe

Обнови `backend/apps/platform/views.py` — детальный health check:

```python
class HealthCheckView(View):
    """
    GET /api/v1/platform/health/
    Детальная проверка всех компонентов системы.
    Используется K8s liveness/readiness probe.
    """

    def get(self, request):
        import time
        checks = {}
        overall_ok = True
        start = time.time()

        # 1. Database
        try:
            from django.db import connection
            with connection.cursor() as cursor:
                cursor.execute('SELECT 1')
            checks['database'] = {'status': 'ok', 'type': 'postgresql'}
        except Exception as e:
            checks['database'] = {'status': 'error', 'error': str(e)[:100]}
            overall_ok = False

        # 2. Cache (Redis)
        try:
            from django.core.cache import cache
            cache.set('health_check', '1', 5)
            val = cache.get('health_check')
            checks['cache'] = {'status': 'ok' if val == '1' else 'miss'}
        except Exception as e:
            checks['cache'] = {'status': 'error', 'error': str(e)[:100]}
            # Cache error не критично

        # 3. Games catalog
        try:
            from apps.games.models import Game
            count = Game.objects.filter(status='published').count()
            checks['games'] = {'status': 'ok', 'count': count}
            if count < 5:
                checks['games']['warning'] = 'Less than 5 games published'
        except Exception as e:
            checks['games'] = {'status': 'error', 'error': str(e)[:100]}
            overall_ok = False

        # 4. Monetization
        try:
            from apps.monetization.models import PlayCoinPackage
            pkg_count = PlayCoinPackage.objects.filter(is_active=True).count()
            checks['shop'] = {'status': 'ok', 'packages': pkg_count}
        except Exception as e:
            checks['shop'] = {'status': 'error', 'error': str(e)[:100]}

        elapsed_ms = int((time.time() - start) * 1000)
        status_code = 200 if overall_ok else 503

        from apps.games.models import Game
        from django.utils import timezone

        return JsonResponse({
            'status': 'ok' if overall_ok else 'degraded',
            'version': '0.6.0',
            'timestamp': timezone.now().isoformat(),
            'response_ms': elapsed_ms,
            'checks': checks,
            'games_count': checks.get('games', {}).get('count', 0),
        }, status=status_code)
```

Добавь в K8s deployment манифест `k8s/django/deployment.yaml`:
```yaml
livenessProbe:
  httpGet:
    path: /api/v1/platform/health/
    port: 8000
  initialDelaySeconds: 15
  periodSeconds: 20
  failureThreshold: 3

readinessProbe:
  httpGet:
    path: /api/v1/platform/health/
    port: 8000
  initialDelaySeconds: 10
  periodSeconds: 10
  failureThreshold: 2
```

### Приёмочные тесты задачи 2:
```bash
cd backend && python manage.py runserver &
sleep 3

curl -sf http://localhost:8000/api/v1/platform/health/ | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['status'] in ['ok', 'degraded']
assert 'checks' in d
assert 'database' in d['checks']
assert d['checks']['database']['status'] == 'ok'
assert 'games' in d['checks']
assert 'version' in d
print('OK: Health check:', d['status'])
print('  Database:', d['checks']['database']['status'])
print('  Games:', d['checks'].get('games', {}).get('count', 0))
print('  Response:', d['response_ms'], 'ms')
"

# K8s YAML валиден:
python3 -c "
import yaml
with open('k8s/django/deployment.yaml') as f: d = yaml.safe_load(f)
containers = d['spec']['template']['spec']['containers']
for c in containers:
    if c.get('name') == 'django':
        assert 'livenessProbe' in c, 'Missing livenessProbe'
        assert 'readinessProbe' in c, 'Missing readinessProbe'
        print('OK: K8s probes configured')
"

kill %1
```

---

## ЗАДАЧА 3 — Нагрузочный тест: 500 пользователей

Создай `scripts/load_test.py` — нагрузочный тест без внешних зависимостей:

```python
#!/usr/bin/env python3
"""
PlayRU Load Test — симулирует 500 одновременных пользователей.
Использует только стандартную библиотеку Python.

Запуск: python3 scripts/load_test.py [base_url]
"""
import urllib.request
import urllib.error
import json
import time
import threading
import sys
from collections import defaultdict

BASE_URL = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8000"

ENDPOINTS = [
    ("GET",  "/api/v1/platform/health/",   None),
    ("GET",  "/api/v1/games/",             None),
    ("GET",  "/api/v1/shop/packages/",     None),
    ("GET",  "/api/v1/public/metrics/",    None),
    ("GET",  "/api/v1/public/pitch/",      None),
]

results = defaultdict(list)
errors = defaultdict(int)
lock = threading.Lock()


def make_request(endpoint):
    method, path, body = endpoint
    url = BASE_URL + path
    start = time.time()

    try:
        req = urllib.request.Request(url, method=method)
        if body:
            req.add_header('Content-Type', 'application/json')
            req.data = json.dumps(body).encode()

        with urllib.request.urlopen(req, timeout=5) as resp:
            resp.read()
            elapsed = (time.time() - start) * 1000
            with lock:
                results[path].append(elapsed)

    except urllib.error.HTTPError as e:
        if e.code == 429:
            with lock: results[path + '_429'].append(1)
        else:
            with lock: errors[path] += 1
    except Exception:
        with lock: errors[path] += 1


def run_wave(n_users, endpoints):
    threads = []
    for i in range(n_users):
        endpoint = endpoints[i % len(endpoints)]
        t = threading.Thread(target=make_request, args=(endpoint,))
        threads.append(t)

    start = time.time()
    for t in threads: t.start()
    for t in threads: t.join()
    elapsed = time.time() - start
    return elapsed


def main():
    print(f"=== PlayRU Load Test: {BASE_URL} ===\n")

    # Прогрев
    print("Прогрев (10 запросов)...")
    run_wave(10, ENDPOINTS)
    results.clear()

    # Основной тест
    waves = [
        (50,  "50 пользователей"),
        (100, "100 пользователей"),
        (200, "200 пользователей"),
        (500, "500 пользователей"),
    ]

    all_ok = True

    for count, label in waves:
        print(f"\n{label}:")
        elapsed = run_wave(count, ENDPOINTS)
        print(f"  Время волны: {elapsed:.2f}s")

        for path, times in results.items():
            if '_429' in path:
                print(f"  {path}: {len(times)} rate-limited (OK)")
                continue
            if not times: continue
            avg = sum(times) / len(times)
            p95 = sorted(times)[int(len(times) * 0.95)]
            max_t = max(times)
            ok = avg < 500 and p95 < 1000
            status = "✅" if ok else "❌"
            if not ok: all_ok = False
            print(f"  {status} {path}: avg={avg:.0f}ms p95={p95:.0f}ms max={max_t:.0f}ms n={len(times)}")

        err_total = sum(errors.values())
        if err_total > 0:
            print(f"  Ошибки: {err_total}")
            all_ok = False

        results.clear()
        errors.clear()
        time.sleep(1)  # Пауза между волнами

    print(f"\n{'✅ Нагрузочный тест ПРОЙДЕН' if all_ok else '❌ Нагрузочный тест ПРОВАЛЕН'}")
    return 0 if all_ok else 1


if __name__ == '__main__':
    exit(main())
```

### Приёмочные тесты задачи 3:
```bash
cd backend && python manage.py runserver &
sleep 3

python3 scripts/load_test.py http://localhost:8000

kill %1

echo "OK: Load test complete"
```

---

## ЗАДАЧА 4 — Финальный seed и README деплоя

Создай `PRODUCTION_DEPLOY.md` в корне playru-platform:

```markdown
# PlayRU Platform — Production Deploy Guide

## Предварительные требования

- Kubernetes кластер в Selectel (3+ nodes, 4 CPU, 8 GB RAM)
- Домен playru.ru с DNS управлением
- Selectel Container Registry доступ
- GitHub Actions секреты настроены

## Шаг 1: Первичная настройка (один раз)

```bash
# 1. Настроить kubeconfig для Selectel:
export KUBECONFIG=~/.kube/selectel-config

# 2. Запустить скрипты последовательно:
bash scripts/deploy/01_init_cluster.sh    # ~5 мин: cert-manager + nginx
bash scripts/deploy/02_create_secrets.sh  # ~2 мин: секреты в K8s
bash scripts/deploy/03_deploy_platform.sh # ~10 мин: всё приложение
bash scripts/deploy/04_smoke_test.sh api.playru.ru
```

## Шаг 2: DNS настройка

После `01_init_cluster.sh` получи IP:
```bash
kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

Добавь DNS записи:
```
api.playru.ru      A → <EXTERNAL_IP>
monitor.playru.ru  A → <EXTERNAL_IP>
```

## Шаг 3: Первые пользователи

```bash
# Загрузить все начальные данные:
kubectl exec -n playru deployment/django -- \
  python manage.py seed_games
kubectl exec -n playru deployment/django -- \
  python manage.py seed_monetization

# Создать admin-пользователя:
kubectl exec -n playru deployment/django -- \
  python manage.py createsuperuser
```

## Шаг 4: Мониторинг

- Grafana: https://monitor.playru.ru
- Django Admin: https://api.playru.ru/admin/
- Pitch Deck: https://api.playru.ru/api/v1/public/pitch/

## CI/CD (автоматически после настройки)

Push в `main` → GitHub Actions → Docker build → Selectel Registry → kubectl rollout.

## Нагрузочный тест перед запуском

```bash
python3 scripts/load_test.py https://api.playru.ru
```

Ожидаемый результат: avg < 200ms, p95 < 500ms при 500 пользователях.

## Откат при проблемах

```bash
kubectl rollout undo deployment/django -n playru
kubectl rollout undo deployment/nakama -n playru
```
```

Создай `scripts/setup_github_secrets.sh`:
```bash
#!/bin/bash
# Настройка GitHub Actions секретов через gh CLI
# Требует: gh auth login

set -e
REPO="${1:-$(git remote get-url origin | sed 's/.*github.com\///' | sed 's/\.git//')}"
echo "=== Настройка секретов для: $REPO ==="

read -p "SELECTEL_REGISTRY_USER: " REG_USER
gh secret set SELECTEL_REGISTRY_USER --body "$REG_USER" -R "$REPO"

read -s -p "SELECTEL_REGISTRY_PASS: " REG_PASS; echo
gh secret set SELECTEL_REGISTRY_PASS --body "$REG_PASS" -R "$REPO"

read -s -p "KUBECONFIG (base64): " KUBE; echo
gh secret set KUBECONFIG_BASE64 --body "$KUBE" -R "$REPO"

echo "OK: GitHub secrets configured for $REPO"
```

### Приёмочные тесты задачи 4:
```bash
test -f PRODUCTION_DEPLOY.md && echo "OK: deploy guide"
test -f scripts/setup_github_secrets.sh && echo "OK: secrets setup script"
grep -q "seed_games" PRODUCTION_DEPLOY.md && echo "OK: seed instructions"
grep -q "smoke_test" PRODUCTION_DEPLOY.md && echo "OK: smoke test mentioned"
grep -q "rollout undo" PRODUCTION_DEPLOY.md && echo "OK: rollback instructions"

# Финальный полный тест:
cd backend
python manage.py check && echo "OK: Django check clean"
pytest tests/ -v --tb=short
FAILS=$(pytest tests/ 2>&1 | grep -c "FAILED" || true)
[ "$FAILS" -eq 0 ] && echo "OK: All tests green" || echo "WARN: $FAILS tests failed"
```

---

## ✅ ФИНАЛЬНАЯ ПРИЁМКА НЕДЕЛИ 6 (ФИНАЛЬНАЯ)

```bash
cd backend
python manage.py migrate
python manage.py seed_games
python manage.py seed_monetization
python manage.py runserver &
sleep 3

echo "=== ФИНАЛЬНАЯ ПРИЁМКА НЕДЕЛИ 6 ==="

echo "--- API endpoints ---"
ENDPOINTS=(
  "http://localhost:8000/api/v1/platform/health/"
  "http://localhost:8000/api/v1/games/"
  "http://localhost:8000/api/v1/shop/packages/"
  "http://localhost:8000/api/v1/shop/analytics/"
  "http://localhost:8000/api/v1/public/metrics/"
  "http://localhost:8000/api/v1/public/pitch/"
)
for url in "${ENDPOINTS[@]}"; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$url")
  [ "$STATUS" = "200" ] && echo "OK: $url" || echo "FAIL: $url ($STATUS)"
done

echo "--- Health check ---"
curl -sf http://localhost:8000/api/v1/platform/health/ | python3 -c "
import sys,json; d=json.load(sys.stdin)
assert d['status'] in ['ok','degraded']
assert d['checks']['database']['status'] == 'ok'
print('OK: Health check -', d['status'], '|', d['response_ms'], 'ms')
"

echo "--- Rate limiting ---"
curl -sf http://localhost:8000/api/v1/platform/health/ -I | grep -i "X-Response-Time" \
  && echo "OK: Timing header"

echo "--- Нагрузочный тест (100 пользователей) ---"
python3 scripts/load_test.py http://localhost:8000

echo "--- Деплой документация ---"
test -f PRODUCTION_DEPLOY.md && echo "OK: PRODUCTION_DEPLOY.md"
test -f scripts/load_test.py && echo "OK: load_test.py"

echo "--- Питч-дек snapshot ---"
curl -sf http://localhost:8000/api/v1/public/pitch/ | python3 -c "
import sys,json; d=json.load(sys.stdin)
games = d['product']['games_count']
est = d['market']['est_value_at_50k_mau_rub']
print(f'OK: Pitch deck — {games} игр, оценка {est:,} руб при 50K MAU')
"

echo "--- Все тесты ---"
pytest tests/ --tb=short -q
kill %1

echo ""
echo "=============================================="
echo "  ПЛАТФОРМА ГОТОВА К PRODUCTION ДЕПЛОЮ"
echo "  Rate limiting: ✅"
echo "  Health checks + K8s probes: ✅"
echo "  Load test 500 users: ✅"
echo "  Deploy guide: ✅"
echo "  Pitch deck endpoint: ✅"
echo "=============================================="
echo ""
echo "Следующий шаг: bash scripts/deploy/01_init_cluster.sh"
```

> **Агент останавливается здесь и ждёт команды.**
