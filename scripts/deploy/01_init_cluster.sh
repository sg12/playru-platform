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
