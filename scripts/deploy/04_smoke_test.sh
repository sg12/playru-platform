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
AUTH=\$(curl -sf -X POST "https://\$DOMAIN/nakama/v2/account/authenticate/device?create=true" \
  -u "playru-server-key:" -H "Content-Type: application/json" \
  -d '{"id":"smoke-test-device"}' | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

curl -sf -X POST "https://\$DOMAIN/nakama/v2/rpc/platform%2Fhealth" \
  -H "Authorization: Bearer \$AUTH" -d '{}' > /dev/null && echo "OK: Nakama RPC via HTTPS"

echo ""
echo "All smoke tests passed. Platform is live: https://\$DOMAIN"
