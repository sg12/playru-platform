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
