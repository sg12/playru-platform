# PlayRU Platform — Инфраструктура и деплой

## Справка по серверной архитектуре, K8s, Docker и процедурам обновления

**Сервер:** Selectel VPS, 4 vCPU / 8 GB RAM / 80 GB NVMe, Ubuntu 24.04  
**IP:** 77.222.35.13  
**Оркестрация:** K3s (lightweight Kubernetes)  
**Namespace:** `playru`  
**Репозиторий:** https://github.com/sg12/playru-platform  

---

## 1. Архитектура кластера

```
                        ┌─────────────────────────────────┐
                        │        Selectel VPS              │
                        │     77.222.35.13 (Novosibirsk)   │
                        │                                  │
  Интернет ──────────── │  ┌──────────┐                    │
                        │  │ Traefik  │ (Ingress Controller)│
                        │  │ :80/:443 │                    │
                        │  └────┬─────┘                    │
                        │       │                          │
                        │  ┌────┼──────────────────────┐   │
                        │  │ Namespace: playru          │   │
                        │  │                            │   │
                        │  │  ┌─────────┐ ┌──────────┐ │   │
   api.plobox.ru ───────┼──┼─►│ Django  │ │ Nakama   │◄┼───┼── ws.plobox.ru
   plobox.ru ───────────┼──┼─►│ :8000   │ │ :7350 API│ │   │
   dev.plobox.ru ───────┼──┼─►│         │ │ :7351 Con│◄┼───┼── monitor.plobox.ru
                        │  │  └────┬────┘ └────┬─────┘ │   │
                        │  │       │           │        │   │
                        │  │  ┌────▼───────────▼─────┐  │   │
                        │  │  │   PostgreSQL 15       │  │   │
                        │  │  │   :5432               │  │   │
                        │  │  │   БД: nakama + django  │  │   │
                        │  │  └──────────────────────┘  │   │
                        │  └────────────────────────────┘   │
                        └───────────────────────────────────┘
```

## 2. Поды (Pods)

| Pod | Image | Порты | Назначение |
|-----|-------|-------|-----------|
| `django-*` | `playru-backend:latest` (локальный build) | 8000 | REST API, Admin, витрина, каталог игр |
| `nakama-*` | `heroiclabs/nakama:3.22.0` (Docker Hub) | 7349 (gRPC), 7350 (HTTP/WS), 7351 (Console) | Игровой сервер: auth, мультиплеер, экономика, лидерборды |
| `postgres-*` | `postgres:15` (Docker Hub) | 5432 | Две базы: nakama + django |

Проверка состояния:
```bash
kubectl get pods -n playru
```

## 3. ConfigMaps

| ConfigMap | Содержимое | Используется в |
|-----------|-----------|---------------|
| `nakama-config` | `config.yml` — конфигурация Nakama (DSN, порты, ключи) | Pod nakama, mount `/nakama/config.yml` |
| `nakama-modules` | 17 Lua-файлов — вся серверная логика | Pod nakama, mount `/nakama/data/modules/` |

Просмотр:
```bash
kubectl get configmaps -n playru
kubectl describe configmap nakama-modules -n playru
kubectl describe configmap nakama-config -n playru
```

## 4. Lua-модули Nakama (17 файлов)

```
nakama/modules/
├── init.lua                          # Точка входа: require всех модулей, регистрация хуков
├── auth_vk.lua                       # Авторизация через VK ID
├── auth_yandex.lua                   # Авторизация через Яндекс ID
├── economy.lua                       # Кошелёк, daily reward, история транзакций
├── premium.lua                       # Premium подписка, award_coins
├── achievements.lua                  # Система достижений
├── notifications.lua                 # Уведомления
├── platform_leaderboard.lua          # Платформенный лидерборд
│
├── match_handler.lua                 # Базовый авторитативный match handler (мультиплеер)
├── room_manager.lua                  # Комнаты, invite-коды, matchmaking
├── games_island_survival_mp.lua      # Мультиплеерный Island Survival (750 строк)
│
├── games_clicker.lua                 # Кликер (sync, buy_upgrade, state)
├── games_parkour.lua                 # Паркур (submit_score, leaderboard)
├── games_arena.lua                   # Арена (submit_result, leaderboard)
├── games_racing.lua                  # Гонки (submit_result, leaderboard)
├── games_tower_defense.lua           # Tower Defense (submit_result, leaderboard)
└── games_island_survival.lua         # Island Survival одиночный (submit_result, leaderboard)
```

**Важно про Lua match handlers в Nakama:**
- Модуль возвращает таблицу `M` с функциями `match_init`, `match_loop` и т.д.
- `nk.match_create("имя_файла_без_lua", params)` — имя модуля = имя файла
- **НЕ использовать** `nk.register_match()` — такой функции нет в Nakama Lua runtime
- `nk.register_matchmaker_matched()` — это другая, валидная функция

## 5. Docker-образы

### Django (собирается локально на сервере)

```bash
# Dockerfile: /opt/playru-platform/backend/Dockerfile
# Image name: playru-django (хранится в containerd k3s)

# Сборка и деплой:
cd /opt/playru-platform
git pull
docker build --no-cache -t playru-django:vN ./backend/    # N — инкрементируй каждый раз!
docker save playru-django:vN | k3s ctr images import -
kubectl -n playru set image deployment/django django=playru-django:vN
kubectl -n playru rollout status deployment/django
```

**ВАЖНО:**
- Container runtime: **containerd** (НЕ Docker). Docker-образы невидимы для k3s — нужен `docker save | k3s ctr images import -`
- `imagePullPolicy: Never` — k8s никогда не скачивает образ, только берёт из локального containerd
- **Обязательно инкрементировать тег** (v2, v3, v4...) — иначе k8s не подхватит новый образ при `rollout restart`
- `--no-cache` обязателен — иначе Docker переиспользует слои с устаревшим кодом
- `rollout restart` **НЕ работает** для обновления образа — нужен `set image` с новым тегом
- Текущий тег на сервере: `playru-django:v3` (на 10 марта 2026)

Dockerfile включает: Python 3.11-slim, Django 4.2, DRF, psycopg2, gunicorn, whitenoise, collectstatic, entrypoint.sh.

### Nakama (официальный образ)

```
heroiclabs/nakama:3.22.0
```

Не собирается — используется as-is из Docker Hub. Кастомизация через ConfigMap с Lua-модулями.

### PostgreSQL (официальный образ)

```
postgres:15
```

## 6. Ingress (Traefik)

4 правила маршрутизации:

| URL | Сервис | Порт |
|-----|--------|------|
| `https://api.plobox.ru` | Django | 8000 |
| `https://plobox.ru` | Django | 8000 |
| `https://dev.plobox.ru` | Django | 8000 |
| `https://ws.plobox.ru` | Nakama | 7350 |
| `https://monitor.plobox.ru` | Nakama | 7351 |

SSL через cert-manager + Let's Encrypt (auto-renewal).

Просмотр:
```bash
kubectl get ingress -n playru
```

## 7. Ресурсы подов

| Pod | CPU request | CPU limit | RAM request | RAM limit |
|-----|-------------|-----------|-------------|-----------|
| Nakama | 100m | 500m | — | 512Mi |
| Django | — | — | — | — |
| PostgreSQL | — | — | — | — |

Общее потребление сервера: ~41% RAM (при idle).

---

## 8. Процедуры обновления

### 8.1 Обновление Lua-модулей Nakama (самое частое)

Когда изменились файлы в `nakama/modules/`:

```bash
# 1. Подключиться к серверу
ssh root@77.222.35.13

# 2. Подтянуть код
cd /opt/playru-platform
git pull

# 3. Обновить ConfigMap
cd nakama/modules
kubectl delete configmap nakama-modules -n playru
kubectl create configmap nakama-modules --namespace=playru --from-file=.

# 4. Рестарт Nakama (подхватит новые модули)
kubectl rollout restart deployment/nakama -n playru

# 5. Проверить
sleep 30
kubectl get pods -n playru | grep nakama    # должен быть 1/1 Running
kubectl logs -n playru -l app=nakama --tail=20 | grep -E "error|fatal|API server"
```

**Время простоя:** ~30 секунд (старый pod работает пока новый стартует).

### 8.2 Обновление Django-бэкенда

Когда изменился код в `backend/`:

```bash
# 1. Подтянуть код
cd /opt/playru-platform
git pull

# 2. Пересобрать Docker-образ (ОБЯЗАТЕЛЬНО: --no-cache + новый тег!)
docker build --no-cache -t playru-django:vN ./backend/

# 3. Импортировать в containerd (Docker-образы невидимы для k3s!)
docker save playru-django:vN | k3s ctr images import -

# 4. Обновить образ в deployment (rollout restart НЕ обновляет образ!)
kubectl -n playru set image deployment/django django=playru-django:vN
kubectl -n playru rollout status deployment/django

# 5. Миграции (если были изменения в моделях)
kubectl -n playru exec deploy/django -- python manage.py migrate

# 6. Seed data (если добавили новые игры/пакеты)
kubectl -n playru exec deploy/django -- python manage.py seed_games
kubectl -n playru exec deploy/django -- python manage.py seed_monetization

# 7. Проверить
kubectl -n playru exec deploy/django -- cat /app/config/urls.py   # убедиться что код обновился
curl -s https://api.plobox.ru/api/v1/platform/health/ | python3 -m json.tool
```

### 8.3 Полное обновление (Lua + Django)

```bash
ssh root@77.222.35.13
cd /opt/playru-platform
git pull

# Django (инкрементировать тег!)
docker build --no-cache -t playru-django:vN ./backend/
docker save playru-django:vN | k3s ctr images import -
kubectl -n playru set image deployment/django django=playru-django:vN
kubectl -n playru rollout status deployment/django

# Nakama
cd nakama/modules
kubectl delete configmap nakama-modules -n playru
kubectl create configmap nakama-modules --namespace=playru --from-file=.
kubectl rollout restart deployment/nakama -n playru

# Ждём и проверяем
sleep 30
kubectl get pods -n playru
curl -s https://api.plobox.ru/api/v1/platform/health/ | python3 -m json.tool
curl -sk https://ws.plobox.ru/healthcheck
```

### 8.4 Обновление конфигурации Nakama

Когда нужно изменить `config.yml` (порты, ключи, DSN):

```bash
kubectl edit configmap nakama-config -n playru
# или
kubectl delete configmap nakama-config -n playru
kubectl create configmap nakama-config --namespace=playru --from-file=config.yml=path/to/config.yml
kubectl rollout restart deployment/nakama -n playru
```

---

## 9. Диагностика

### Логи

```bash
# Nakama (последние 100 строк)
kubectl logs -n playru -l app=nakama --tail=100

# Django
kubectl logs -n playru -l app=django --tail=100

# PostgreSQL
kubectl logs -n playru -l app=postgres --tail=50

# Следить в реальном времени
kubectl logs -f -n playru -l app=nakama
```

### Статус

```bash
# Все поды
kubectl get pods -n playru

# Детали конкретного пода
kubectl describe pod <pod-name> -n playru

# Ресурсы
kubectl top pods -n playru    # если metrics-server установлен

# Health checks
curl -s https://api.plobox.ru/api/v1/platform/health/ | python3 -m json.tool
curl -sk https://ws.plobox.ru/healthcheck
```

### Частые проблемы

| Симптом | Причина | Решение |
|---------|---------|---------|
| Nakama CrashLoopBackOff | Ошибка в Lua-модуле | `kubectl logs <pod> -n playru` → найти `error`/`fatal` → исправить Lua |
| Django CrashLoopBackOff | Ошибка в Python/миграциях | `kubectl logs <pod> -n playru` → исправить код |
| `nk.register_match` error | Нет такой функции в Nakama Lua | Удалить вызов, модуль должен просто `return M` |
| ConfigMap не обновился | K8s кэширует ConfigMap | `kubectl delete` + `kubectl create` (не `apply`) |
| Старый pod не удаляется | Rolling update ждёт новый pod | Проверить статус нового пода, при необходимости `kubectl delete pod` |
| ErrImageNeverPull | Образ не импортирован в containerd | `docker save <image> \| k3s ctr images import -` |
| Код не обновился после rollout restart | `imagePullPolicy: Never` + тот же тег | Собрать с новым тегом + `kubectl set image` |
| `docker build` использует кеш | Docker кеширует слои COPY | Добавить `--no-cache` к `docker build` |
| Media 404 на проде | `django.conf.urls.static` не работает при DEBUG=False | Используем `re_path` + `django.views.static.serve` |

### Откат

```bash
# Откатить deployment к предыдущей версии
kubectl rollout undo deployment/nakama -n playru
kubectl rollout undo deployment/django -n playru

# Откатить ConfigMap — только через git
cd /opt/playru-platform
git log --oneline nakama/modules/   # найти предыдущий коммит
git checkout <commit> -- nakama/modules/
# далее пересоздать configmap как в 8.1
```

---

## 10. Доступы

| Ресурс | Адрес | Логин |
|--------|-------|-------|
| SSH | `ssh root@77.222.35.13` | root + password |
| Django Admin | `https://api.plobox.ru/admin/` | superuser |
| Nakama Console | `https://monitor.plobox.ru` | admin/password (сменить!) |
| GitHub | `https://github.com/sg12/playru-platform` | sg12 + token |

**⚠️ Nakama warnings в логах:**
Конфигурация содержит дефолтные ключи для console.username, console.password, socket.server_key, session.encryption_key. Перед публичным запуском — сменить в `nakama-config` ConfigMap.

---

## 11. Структура репозитория

```
playru-platform/
├── backend/                    # Django-приложение
│   ├── Dockerfile
│   ├── requirements.txt
│   ├── manage.py
│   ├── config/                 # settings, urls
│   ├── apps/
│   │   ├── platform/           # ядро: профили, модерация
│   │   ├── games/              # каталог игр, REST API
│   │   ├── monetization/       # PlayCoin, транзакции
│   │   ├── developer/          # портал разработчика
│   │   └── store/              # публичная витрина
│   └── entrypoint.sh
│
├── nakama/
│   ├── modules/                # 17 Lua-модулей (→ ConfigMap)
│   └── config.yml              # конфигурация Nakama
│
├── k8s/                        # Kubernetes манифесты (если есть)
│
└── scripts/                    # утилиты деплоя и тестов
```

---

## 12. Media-файлы

- `MEDIA_ROOT: /app/media` (в production.py не переопределяется, берётся из base.py)
- `MEDIA_URL: /media/`
- Media раздаётся через `django.views.static.serve` (в urls.py), НЕ через `static()` (которая не работает при `DEBUG=False`)
- WhiteNoise раздаёт только **static**, НЕ media
- PVC `django-media-pvc` — shared volume (hostPath на `/dev/vda1`), данные сохраняются при рестарте подов
- Файлы загружаются через Django Admin или developer portal
- Для ручной загрузки: `kubectl -n playru cp <file> <pod-name>:/app/media/<path>`

### Загрузка файла с локальной машины на сервер

```bash
# 1. С локального Mac на VPS
scp /path/to/file root@77.222.35.13:/tmp/file

# 2. С VPS в pod (сначала узнать имя пода)
kubectl -n playru get pods -l app=django
kubectl -n playru exec deploy/django -- mkdir -p /app/media/games/pck/
kubectl -n playru cp /tmp/file <pod-name>:/app/media/games/pck/file
```

---

*Документ обновлён: 10 марта 2026*
