"""
Middleware для защиты PlayRU API.
"""
import json
import time
import hashlib
from django.http import JsonResponse
from django.core.cache import cache


class RateLimitMiddleware:
    """
    Простой rate limiter: 100 запросов/минуту на IP для публичных endpoint'ов.
    Более строгий для /shop/ (10 запросов/минуту).
    """

    LIMITS = {
        '/api/v1/shop/order/': (10, 60),    # 10 req / 60 sec
        '/api/v1/shop/':       (30, 60),    # 30 req / 60 sec
        '/api/v1/':            (100, 60),   # 100 req / 60 sec
    }

    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        ip = self._get_ip(request)
        path = request.path

        for prefix, (limit, window) in self.LIMITS.items():
            if path.startswith(prefix):
                key = f'rl:{hashlib.md5((ip + prefix).encode()).hexdigest()}'
                count = cache.get(key, 0)
                if count >= limit:
                    return JsonResponse({
                        'error': 'Too many requests',
                        'retry_after': window,
                    }, status=429)
                cache.set(key, count + 1, window)
                break

        response = self.get_response(request)
        return response

    def _get_ip(self, request):
        forwarded = request.META.get('HTTP_X_FORWARDED_FOR')
        if forwarded:
            return forwarded.split(',')[0].strip()
        return request.META.get('REMOTE_ADDR', '0.0.0.0')


class RequestTimingMiddleware:
    """Логирует медленные запросы (>500ms)."""

    SLOW_THRESHOLD_MS = 500

    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        start = time.time()
        response = self.get_response(request)
        elapsed_ms = (time.time() - start) * 1000

        if elapsed_ms > self.SLOW_THRESHOLD_MS:
            import logging
            logger = logging.getLogger('playru.performance')
            logger.warning(
                f'SLOW {request.method} {request.path} '
                f'{response.status_code} — {elapsed_ms:.0f}ms'
            )

        response['X-Response-Time'] = f'{elapsed_ms:.0f}ms'
        return response
