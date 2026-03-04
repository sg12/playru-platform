"""
Публичный дашборд PlayRU — для питч-дека Яндексу/VK.
"""
from django.http import JsonResponse
from django.views import View
from django.utils import timezone
from django.core.cache import cache
from datetime import timedelta
from apps.games.models import Game
from apps.platform.models import UserProfile, GameSession, PlatformStats
from apps.monetization.models import Order, PlayCoinPackage


class PublicMetricsView(View):
    """
    GET /api/v1/public/metrics/
    Возвращает ключевые метрики платформы — для питч-дека и публичного дашборда.
    """

    def get(self, request):
        now = timezone.now()
        last_24h = now - timedelta(hours=24)
        last_7d = now - timedelta(days=7)
        last_30d = now - timedelta(days=30)

        # Пользователи
        total_users = UserProfile.objects.count()
        dau = UserProfile.objects.filter(last_seen__gte=last_24h).count()
        wau = UserProfile.objects.filter(last_seen__gte=last_7d).count()
        mau = UserProfile.objects.filter(last_seen__gte=last_30d).count()
        new_today = UserProfile.objects.filter(
            created_at__gte=now.replace(hour=0, minute=0, second=0)
        ).count()

        # Сессии
        sessions_24h = GameSession.objects.filter(started_at__gte=last_24h).count()
        sessions_total = GameSession.objects.count()
        avg_session_qs = GameSession.objects.filter(
            started_at__gte=last_7d,
            duration_seconds__gt=0
        )
        avg_session = 0
        if avg_session_qs.exists():
            total_dur = sum(s.duration_seconds for s in avg_session_qs)
            avg_session = round(total_dur / avg_session_qs.count() / 60, 1)

        # Игры
        games_count = Game.objects.filter(status='published').count()
        top_games = list(
            Game.objects.filter(status='published')
            .order_by('-play_count')[:5]
            .values('title', 'play_count', 'slug')
        )

        # Провайдеры авторизации
        auth_breakdown = {}
        for provider in ['vk', 'yandex', 'guest']:
            auth_breakdown[provider] = UserProfile.objects.filter(
                auth_provider=provider
            ).count()

        return JsonResponse({
            'platform': 'PlayRU',
            'updated_at': now.isoformat(),
            'users': {
                'total': total_users,
                'dau': dau,
                'wau': wau,
                'mau': mau,
                'new_today': new_today,
                'retention_d1': round(dau / max(total_users, 1) * 100, 1),
            },
            'sessions': {
                'last_24h': sessions_24h,
                'total': sessions_total,
                'avg_duration_minutes': avg_session,
            },
            'games': {
                'published': games_count,
                'top': top_games,
            },
            'auth': auth_breakdown,
            'valuation_signal': {
                'mau': mau,
                'est_value_rub': mau * 3000,
                'note': 'Оценка: ~3000 руб/MAU для российских игровых платформ'
            }
        })


class PitchDeckSnapshotView(View):
    """
    GET /api/v1/public/pitch/
    Один endpoint со всеми метриками для питч-дека.
    Кэшируется на 5 минут.
    """

    def get(self, request):
        CACHE_KEY = 'pitch_deck_snapshot'
        cached = cache.get(CACHE_KEY)
        if cached:
            return JsonResponse(cached)

        now = timezone.now()

        # Пользователи
        total = UserProfile.objects.count()
        dau = UserProfile.objects.filter(last_seen__gte=now - timedelta(hours=24)).count()
        mau = UserProfile.objects.filter(last_seen__gte=now - timedelta(days=30)).count()

        # Игры
        games = Game.objects.filter(status='published').order_by('-avg_rating')
        top_games = [
            {'title': g.title, 'rating': float(g.avg_rating),
             'plays': g.play_count, 'genre': g.genre}
            for g in games[:5]
        ]

        # Монетизация
        paid = Order.objects.filter(status='paid')
        revenue = float(sum(o.amount_rub for o in paid))
        paying = paid.values('nakama_user_id').distinct().count()

        # Пакеты
        packages = [
            {'name': p.name, 'price': str(p.price_rub), 'coins': p.total_coins}
            for p in PlayCoinPackage.objects.filter(is_active=True)
        ]

        data = {
            'project': 'PlayRU',
            'tagline': 'Российская игровая платформа для школьников',
            'snapshot_time': now.isoformat(),
            'traction': {
                'total_users': total,
                'dau': dau,
                'mau': mau,
                'dau_mau_ratio': round(dau / max(mau, 1) * 100, 1),
                'paying_users': paying,
                'conversion_pct': round(paying / max(total, 1) * 100, 2),
            },
            'product': {
                'games_count': games.count(),
                'top_games': top_games,
                'platforms': ['Android', 'Web (в разработке)'],
                'min_android_sdk': 24,
            },
            'monetization': {
                'model': 'F2P + PlayCoin + Premium подписка',
                'packages': packages,
                'premium_price_rub': 149,
                'total_revenue_rub': revenue,
                'arpu_rub': round(revenue / max(paying, 1), 2),
            },
            'technology': {
                'client': 'Godot 4 (GDScript)',
                'backend': 'Django 4 + Nakama',
                'database': 'PostgreSQL',
                'infra': 'Kubernetes / ArgoCD / Selectel',
                'auth': ['VK OAuth', 'Yandex OAuth', 'Guest'],
            },
            'market': {
                'target': 'Школьники 6-18 лет, Россия',
                'tam_users': 15_000_000,
                'comparable': 'Roblox (заблокирован в РФ с 2022)',
                'est_value_at_50k_mau_rub': 50_000 * 3_000,
            },
        }

        cache.set(CACHE_KEY, data, 300)
        return JsonResponse(data)
