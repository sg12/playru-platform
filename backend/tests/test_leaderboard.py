"""Tests for Leaderboard API."""

import factory
import pytest
from datetime import timedelta
from django.utils import timezone
from rest_framework.test import APIClient

from apps.games.models import Game
from apps.platform.models import UserProfile, GameSession


class GameFactory(factory.django.DjangoModelFactory):
    class Meta:
        model = Game

    title = factory.Sequence(lambda n: f'LB Game {n}')
    slug = factory.Sequence(lambda n: f'lb-game-{n}')
    description = 'Test'
    status = Game.Status.PUBLISHED


class UserProfileFactory(factory.django.DjangoModelFactory):
    class Meta:
        model = UserProfile

    nakama_user_id = factory.Sequence(lambda n: f'lb-user-{n}')
    display_name = factory.Sequence(lambda n: f'Player {n}')


@pytest.mark.django_db
class TestLeaderboardAPI:
    def setup_method(self):
        self.client = APIClient()
        self.game = GameFactory(slug='lb-test')

    def test_leaderboard_returns_200(self):
        response = self.client.get('/api/v1/games/lb-test/leaderboard/')
        assert response.status_code == 200
        data = response.json()
        assert data['game_slug'] == 'lb-test'
        assert data['period'] == 'all'
        assert 'records' in data
        assert 'total_players' in data

    def test_leaderboard_empty_game(self):
        response = self.client.get('/api/v1/games/lb-test/leaderboard/')
        data = response.json()
        assert data['records'] == []
        assert data['total_players'] == 0

    def test_leaderboard_nonexistent_game(self):
        response = self.client.get('/api/v1/games/nonexistent/leaderboard/')
        assert response.status_code == 404

    def test_leaderboard_with_scores(self):
        # Create sessions with scores
        for i, score in enumerate([100, 300, 200]):
            uid = f'scorer-{i}'
            UserProfileFactory(nakama_user_id=uid, display_name=f'Scorer {i}')
            GameSession.objects.create(
                game=self.game, nakama_user_id=uid, score=score,
            )

        response = self.client.get('/api/v1/games/lb-test/leaderboard/')
        data = response.json()
        assert data['total_players'] == 3
        assert len(data['records']) == 3

        # First place should be highest score
        assert data['records'][0]['score'] == 300
        assert data['records'][0]['rank'] == 1
        assert data['records'][1]['score'] == 200
        assert data['records'][2]['score'] == 100

    def test_leaderboard_best_score_per_player(self):
        uid = 'multi-score'
        UserProfileFactory(nakama_user_id=uid, display_name='Multi')
        # Same player, multiple sessions — should show best
        for score in [50, 200, 100]:
            GameSession.objects.create(
                game=self.game, nakama_user_id=uid, score=score,
            )

        response = self.client.get('/api/v1/games/lb-test/leaderboard/')
        data = response.json()
        assert data['total_players'] == 1
        assert data['records'][0]['score'] == 200

    def test_leaderboard_excludes_zero_scores(self):
        GameSession.objects.create(
            game=self.game, nakama_user_id='zero-score', score=0,
        )
        GameSession.objects.create(
            game=self.game, nakama_user_id='has-score', score=100,
        )
        response = self.client.get('/api/v1/games/lb-test/leaderboard/')
        data = response.json()
        assert data['total_players'] == 1

    def test_leaderboard_display_names(self):
        uid = 'named-player'
        UserProfileFactory(nakama_user_id=uid, display_name='CoolGamer')
        GameSession.objects.create(
            game=self.game, nakama_user_id=uid, score=500,
        )

        response = self.client.get('/api/v1/games/lb-test/leaderboard/')
        data = response.json()
        assert data['records'][0]['display_name'] == 'CoolGamer'

    def test_leaderboard_fallback_display_name(self):
        # No UserProfile — should use truncated ID
        GameSession.objects.create(
            game=self.game, nakama_user_id='abcdefghijklmnop', score=100,
        )
        response = self.client.get('/api/v1/games/lb-test/leaderboard/')
        data = response.json()
        assert data['records'][0]['display_name'] == 'abcdefgh...'

    def test_leaderboard_period_day(self):
        uid = 'today-player'
        GameSession.objects.create(
            game=self.game, nakama_user_id=uid, score=100,
        )
        # Old session
        old = GameSession.objects.create(
            game=self.game, nakama_user_id='old-player', score=999,
        )
        GameSession.objects.filter(pk=old.pk).update(
            started_at=timezone.now() - timedelta(days=3),
        )

        response = self.client.get('/api/v1/games/lb-test/leaderboard/?period=day')
        data = response.json()
        assert data['period'] == 'day'
        assert data['total_players'] == 1
        assert data['records'][0]['nakama_user_id'] == uid

    def test_leaderboard_period_week(self):
        GameSession.objects.create(
            game=self.game, nakama_user_id='week-player', score=100,
        )
        old = GameSession.objects.create(
            game=self.game, nakama_user_id='month-player', score=999,
        )
        GameSession.objects.filter(pk=old.pk).update(
            started_at=timezone.now() - timedelta(days=30),
        )

        response = self.client.get('/api/v1/games/lb-test/leaderboard/?period=week')
        data = response.json()
        assert data['period'] == 'week'
        assert data['total_players'] == 1

    def test_leaderboard_max_50(self):
        for i in range(60):
            GameSession.objects.create(
                game=self.game, nakama_user_id=f'mass-{i}', score=i + 1,
            )

        response = self.client.get('/api/v1/games/lb-test/leaderboard/')
        data = response.json()
        assert len(data['records']) == 50

    def test_leaderboard_isolates_games(self):
        other_game = GameFactory(slug='other-game')
        GameSession.objects.create(
            game=other_game, nakama_user_id='other-player', score=999,
        )
        GameSession.objects.create(
            game=self.game, nakama_user_id='this-player', score=100,
        )

        response = self.client.get('/api/v1/games/lb-test/leaderboard/')
        data = response.json()
        assert data['total_players'] == 1
        assert data['records'][0]['nakama_user_id'] == 'this-player'
