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
