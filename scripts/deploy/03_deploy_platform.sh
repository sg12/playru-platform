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
