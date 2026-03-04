import json

from django.db.models import F
from django.http import JsonResponse
from django.utils.decorators import method_decorator
from django.views import View
from django.views.decorators.csrf import csrf_exempt
from rest_framework import generics, status
from rest_framework.response import Response
from rest_framework.views import APIView

from .models import Game, GameRating
from .serializers import GameDetailSerializer, GameListSerializer


class GameListView(generics.ListAPIView):
    serializer_class = GameListSerializer

    def get_queryset(self):
        return Game.objects.filter(status=Game.Status.PUBLISHED)


class GameDetailView(generics.RetrieveAPIView):
    serializer_class = GameDetailSerializer
    lookup_field = 'slug'

    def get_queryset(self):
        return Game.objects.filter(status=Game.Status.PUBLISHED)


class GameFeaturedView(generics.ListAPIView):
    serializer_class = GameListSerializer

    def get_queryset(self):
        return Game.objects.filter(status=Game.Status.PUBLISHED, is_featured=True)


class GamePlayView(APIView):
    def post(self, request, slug):
        try:
            game = Game.objects.get(slug=slug, status=Game.Status.PUBLISHED)
        except Game.DoesNotExist:
            return Response(
                {'error': 'Game not found'},
                status=status.HTTP_404_NOT_FOUND,
            )
        Game.objects.filter(pk=game.pk).update(play_count=F('play_count') + 1)
        game.refresh_from_db()
        return Response({'play_count': game.play_count})


@method_decorator(csrf_exempt, name='dispatch')
class GameRateView(View):
    """POST /api/v1/games/<slug>/rate/ — Поставить оценку игре."""

    def post(self, request, slug):
        try:
            data = json.loads(request.body)
        except Exception:
            return JsonResponse({'error': 'Invalid JSON'}, status=400)

        try:
            game = Game.objects.get(slug=slug)
        except Game.DoesNotExist:
            return JsonResponse({'error': 'Game not found'}, status=404)

        user_id = data.get('nakama_user_id', '')
        stars = int(data.get('stars', 0))
        if not user_id or stars not in range(1, 6):
            return JsonResponse({'error': 'nakama_user_id and stars 1-5 required'}, status=400)

        rating, created = GameRating.objects.update_or_create(
            game=game, nakama_user_id=user_id,
            defaults={'stars': stars, 'review': data.get('review', '')[:500]}
        )
        game.refresh_from_db()
        action = 'created' if created else 'updated'
        return JsonResponse({
            'success': True,
            'action': action,
            'game_avg_rating': float(game.avg_rating),
            'game_ratings_count': game.ratings_count,
        })


class GameReviewsView(View):
    """GET /api/v1/games/<slug>/reviews/ — список отзывов."""

    def get(self, request, slug):
        try:
            game = Game.objects.get(slug=slug)
        except Game.DoesNotExist:
            return JsonResponse({'error': 'Not found'}, status=404)

        reviews = GameRating.objects.filter(
            game=game, is_approved=True, review__gt=''
        ).order_by('-created_at')[:20]

        return JsonResponse({
            'game': slug,
            'avg_rating': float(game.avg_rating),
            'ratings_count': game.ratings_count,
            'reviews': [
                {
                    'stars': r.stars,
                    'review': r.review,
                    'user_short': r.nakama_user_id[:8] + '...',
                    'date': r.created_at.strftime('%d.%m.%Y'),
                }
                for r in reviews
            ]
        })
