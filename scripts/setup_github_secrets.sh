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
