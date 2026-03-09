from datetime import date, timedelta

from django.db.models import Count, Sum
from django.utils import timezone
from rest_framework import generics, status
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.games.models import Game
from .models import UserProfile, GameSession, PlatformStats
from .serializers import (
    ProfileSyncSerializer, UserProfileSerializer,
    GameSessionSerializer, SessionStartSerializer, SessionEndSerializer,
)


class ProfileDetailView(generics.RetrieveAPIView):
    serializer_class = UserProfileSerializer
    lookup_field = 'nakama_user_id'
    queryset = UserProfile.objects.all()


class ProfileSyncView(APIView):
    def post(self, request):
        serializer = ProfileSyncSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        data = serializer.validated_data

        profile, created = UserProfile.objects.update_or_create(
            nakama_user_id=data['nakama_user_id'],
            defaults={
                'display_name': data['display_name'],
                'avatar_url': data.get('avatar_url', ''),
                'auth_provider': data.get('auth_provider', 'guest'),
                'external_id': data.get('external_id', ''),
            },
        )
        profile.last_seen = timezone.now()
        profile.save(update_fields=['last_seen'])

        result = UserProfileSerializer(profile).data
        result['created'] = created
        return Response(result, status=status.HTTP_201_CREATED if created else status.HTTP_200_OK)


class PlatformHealthView(APIView):
    """
    GET /api/v1/platform/health/
    Детальная проверка всех компонентов системы.
    Используется K8s liveness/readiness probe.
    """

    def get(self, request):
        import time as _time
        from django.http import JsonResponse
        checks = {}
        overall_ok = True
        start = _time.time()

        # 1. Database
        try:
            from django.db import connection
            with connection.cursor() as cursor:
                cursor.execute('SELECT 1')
            checks['database'] = {'status': 'ok', 'type': 'postgresql'}
        except Exception as e:
            checks['database'] = {'status': 'error', 'error': str(e)[:100]}
            overall_ok = False

        # 2. Cache (Redis)
        try:
            from django.core.cache import cache
            cache.set('health_check', '1', 5)
            val = cache.get('health_check')
            checks['cache'] = {'status': 'ok' if val == '1' else 'miss'}
        except Exception as e:
            checks['cache'] = {'status': 'error', 'error': str(e)[:100]}

        # 3. Games catalog
        try:
            count = Game.objects.filter(status='published').count()
            checks['games'] = {'status': 'ok', 'count': count}
            if count < 5:
                checks['games']['warning'] = 'Less than 5 games published'
        except Exception as e:
            checks['games'] = {'status': 'error', 'error': str(e)[:100]}
            overall_ok = False

        # 4. Monetization
        try:
            from apps.monetization.models import PlayCoinPackage
            pkg_count = PlayCoinPackage.objects.filter(is_active=True).count()
            checks['shop'] = {'status': 'ok', 'packages': pkg_count}
        except Exception as e:
            checks['shop'] = {'status': 'error', 'error': str(e)[:100]}

        elapsed_ms = int((_time.time() - start) * 1000)
        status_code = 200 if overall_ok else 503

        return JsonResponse({
            'status': 'ok' if overall_ok else 'degraded',
            'version': '0.6.0',
            'timestamp': timezone.now().isoformat(),
            'response_ms': elapsed_ms,
            'checks': checks,
            'games_count': checks.get('games', {}).get('count', 0),
        }, status=status_code)


class GameLeaderboardView(APIView):
    """GET /api/v1/games/<slug>/leaderboard/?period=all|week|day"""

    def get(self, request, slug):
        game = Game.objects.filter(slug=slug).first()
        if not game:
            return Response({'error': 'Game not found'}, status=status.HTTP_404_NOT_FOUND)

        period = request.query_params.get('period', 'all')

        qs = GameSession.objects.filter(game=game, score__gt=0)
        if period == 'day':
            qs = qs.filter(started_at__date=date.today())
        elif period == 'week':
            qs = qs.filter(started_at__gte=timezone.now() - timedelta(days=7))

        from django.db.models import Max
        top = (
            qs.values('nakama_user_id')
            .annotate(best_score=Max('score'))
            .order_by('-best_score')[:50]
        )

        user_ids = [r['nakama_user_id'] for r in top]
        profiles = {
            p.nakama_user_id: p.display_name
            for p in UserProfile.objects.filter(nakama_user_id__in=user_ids)
        }

        records = []
        for rank, row in enumerate(top, 1):
            uid = row['nakama_user_id']
            records.append({
                'rank': rank,
                'nakama_user_id': uid,
                'display_name': profiles.get(uid, uid[:8] + '...'),
                'score': row['best_score'],
            })

        return Response({
            'game_slug': slug,
            'period': period,
            'total_players': len(records),
            'records': records,
        })


class SessionStartView(APIView):
    def post(self, request):
        serializer = SessionStartSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        data = serializer.validated_data

        game = Game.objects.filter(slug=data['game_slug']).first()

        session = GameSession.objects.create(
            nakama_user_id=data['nakama_user_id'],
            game=game,
            platform=data.get('platform', 'android'),
        )

        return Response(
            GameSessionSerializer(session).data,
            status=status.HTTP_201_CREATED,
        )


class SessionEndView(APIView):
    def post(self, request, session_id):
        try:
            session = GameSession.objects.get(session_id=session_id)
        except GameSession.DoesNotExist:
            return Response(
                {'error': 'Session not found'},
                status=status.HTTP_404_NOT_FOUND,
            )

        serializer = SessionEndSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        data = serializer.validated_data

        session.score = data.get('score', 0)
        session.completed = data.get('completed', False)
        session.duration_seconds = data.get('duration_seconds', 0)
        session.ended_at = timezone.now()
        session.save()

        return Response(GameSessionSerializer(session).data)


class StatsSummaryView(APIView):
    def get(self, request):
        today = date.today()
        total_sessions = GameSession.objects.count()
        total_users = UserProfile.objects.count()
        today_sessions = GameSession.objects.filter(started_at__date=today).count()
        today_users = GameSession.objects.filter(
            started_at__date=today
        ).values('nakama_user_id').distinct().count()

        total_playtime = GameSession.objects.aggregate(
            total=Sum('duration_seconds')
        )['total'] or 0

        return Response({
            'date': today.isoformat(),
            'dau': today_users,
            'total_users': total_users,
            'total_sessions': total_sessions,
            'today_sessions': today_sessions,
            'total_playtime_hours': round(total_playtime / 3600, 2),
        })
