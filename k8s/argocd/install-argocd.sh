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
