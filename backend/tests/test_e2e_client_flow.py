"""
E2E тест: симуляция полного flow мобильного клиента PlayRU.
Этот тест запускается когда docker compose up активен.
Пропускается если Nakama или Django недоступны.
"""
import pytest
import requests
import json

NAKAMA_URL = "http://localhost:7350"
DJANGO_URL = "http://localhost:8000"
SERVER_KEY = "playru-server-key"


@pytest.fixture(scope="module")
def nakama_available():
    try:
        r = requests.get(f"{NAKAMA_URL}/", timeout=3)
        return r.status_code == 200
    except Exception:
        return False


@pytest.fixture(scope="module")
def django_available():
    try:
        r = requests.get(f"{DJANGO_URL}/api/v1/platform/health/", timeout=3)
        return r.status_code == 200
    except Exception:
        return False


@pytest.fixture(scope="module")
def auth_token(nakama_available):
    if not nakama_available:
        pytest.skip("Nakama unavailable")
    import time
    device_id = f"e2e-test-{int(time.time())}"
    r = requests.post(
        f"{NAKAMA_URL}/v2/account/authenticate/device?create=true",
        auth=(SERVER_KEY, ""),
        json={"id": device_id}
    )
    assert r.status_code == 200
    return r.json()["token"]


def rpc(token, rpc_id, payload=None):
    url = f"{NAKAMA_URL}/v2/rpc/{rpc_id.replace('/', '%2F')}"
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }
    if payload:
        body = json.dumps(json.dumps(payload))
    else:
        body = '""'
    r = requests.post(url, headers=headers, data=body)
    assert r.status_code == 200, f"RPC {rpc_id} failed: {r.text}"
    data = r.json()
    raw = data.get("payload", "{}")
    if isinstance(raw, str):
        return json.loads(raw)
    return raw


class TestClientFlow:

    def test_01_platform_health_nakama(self, auth_token):
        """Клиент проверяет что платформа живая"""
        result = rpc(auth_token, "platform/health")
        assert result["status"] == "ok"
        assert result["platform"] == "PlayRU"
        print(f"  Platform version: {result.get('version')}")

    def test_02_wallet_welcome_bonus(self, auth_token):
        """Новый игрок получает 100 стартовых монет"""
        result = rpc(auth_token, "economy/wallet")
        assert result["playcoin"] >= 100
        print(f"  Wallet: {result['playcoin']} PlayCoin")

    def test_03_daily_reward(self, auth_token):
        """Игрок получает ежедневную награду"""
        result = rpc(auth_token, "economy/daily_reward")
        assert result["success"] is True
        assert result["coins_earned"] == 50
        print(f"  Daily reward: +{result['coins_earned']} PlayCoin")

    def test_04_daily_reward_duplicate(self, auth_token):
        """Повторный запрос ежедневной награды отклоняется"""
        result = rpc(auth_token, "economy/daily_reward")
        assert result["success"] is False
        print("  Duplicate daily reward: correctly rejected")

    def test_05_games_catalog_django(self, django_available):
        """Каталог игр возвращает данные"""
        if not django_available:
            pytest.skip("Django unavailable")
        r = requests.get(f"{DJANGO_URL}/api/v1/games/")
        assert r.status_code == 200
        data = r.json()
        assert data["count"] >= 4
        print(f"  Games catalog: {data['count']} games")

    def test_06_featured_games(self, django_available):
        """Рекомендованные игры возвращаются"""
        if not django_available:
            pytest.skip("Django unavailable")
        r = requests.get(f"{DJANGO_URL}/api/v1/games/featured/")
        assert r.status_code == 200
        data = r.json()
        results = data.get("results", data) if isinstance(data, dict) else data
        assert len(results) >= 2
        print(f"  Featured games: {len(results)}")

    def test_07_profile_sync(self, auth_token, django_available):
        """Профиль синхронизируется между Nakama и Django"""
        if not django_available:
            pytest.skip("Django unavailable")
        import time
        test_id = f"e2e-user-{int(time.time())}"
        r = requests.post(
            f"{DJANGO_URL}/api/v1/profile/sync/",
            json={
                "nakama_user_id": test_id,
                "display_name": "E2E Тест Игрок",
                "auth_provider": "guest"
            }
        )
        assert r.status_code in [200, 201]
        data = r.json()
        assert data["display_name"] == "E2E Тест Игрок"
        print(f"  Profile synced: {data['display_name']}")

    def test_08_parkour_submit_score(self, auth_token):
        """Результат паркура сохраняется и начисляются монеты"""
        wallet_before = rpc(auth_token, "economy/wallet")
        coins_before = wallet_before["playcoin"]

        result = rpc(auth_token, "games/parkour/submit_score", {
            "time": 42.5,
            "deaths": 2,
            "level": "level1"
        })
        assert result["success"] is True
        assert result["coins_earned"] > 0

        wallet_after = rpc(auth_token, "economy/wallet")
        coins_after = wallet_after["playcoin"]
        assert coins_after > coins_before
        print(f"  Score submitted: +{result['coins_earned']} PlayCoin ({coins_before} -> {coins_after})")

    def test_09_parkour_leaderboard(self, auth_token):
        """Лидерборд паркура возвращает записи"""
        result = rpc(auth_token, "games/parkour/leaderboard", {"level": "level1"})
        assert "records" in result
        assert len(result["records"]) >= 1
        print(f"  Leaderboard: {len(result['records'])} records")

    def test_10_wallet_history_complete(self, auth_token):
        """История кошелька отражает все транзакции"""
        result = rpc(auth_token, "economy/wallet_history")
        assert result["count"] >= 3  # welcome + daily + parkour
        print(f"  Wallet history: {result['count']} transactions")
