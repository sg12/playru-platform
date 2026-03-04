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
            status = "PASS" if ok else "FAIL"
            if not ok: all_ok = False
            print(f"  {status} {path}: avg={avg:.0f}ms p95={p95:.0f}ms max={max_t:.0f}ms n={len(times)}")

        err_total = sum(errors.values())
        err_pct = (err_total / count * 100) if count > 0 else 0
        if err_total > 0:
            print(f"  Ошибки: {err_total} ({err_pct:.1f}%)")
            if err_pct > 5:
                all_ok = False

        results.clear()
        errors.clear()
        time.sleep(1)  # Пауза между волнами

    print(f"\n{'PASS: Нагрузочный тест ПРОЙДЕН' if all_ok else 'FAIL: Нагрузочный тест ПРОВАЛЕН'}")
    return 0 if all_ok else 1


if __name__ == '__main__':
    exit(main())
