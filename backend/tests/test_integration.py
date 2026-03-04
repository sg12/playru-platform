import pytest
from django.test import TestCase
from rest_framework.test import APIClient

from apps.games.models import Game


@pytest.mark.django_db
class TestIntegration:
    """Integration tests for the PlayRU platform."""

    def setup_method(self):
        self.client = APIClient()
        # Create test data
        Game.objects.create(
            title='Test Game 1', slug='test-game-1',
            description='Desc', short_description='Short',
            status=Game.Status.PUBLISHED, is_featured=True,
        )
        Game.objects.create(
            title='Test Game 2', slug='test-game-2',
            description='Desc', short_description='Short',
            status=Game.Status.PUBLISHED, is_featured=False,
        )
        Game.objects.create(
            title='Draft Game', slug='draft-game',
            description='Desc', short_description='Short',
            status=Game.Status.DRAFT,
        )

    def test_games_list_excludes_drafts(self):
        response = self.client.get('/api/v1/games/')
        assert response.status_code == 200
        data = response.json()
        assert data['count'] == 2
        slugs = [g['slug'] for g in data['results']]
        assert 'draft-game' not in slugs

    def test_featured_only_returns_featured(self):
        response = self.client.get('/api/v1/games/featured/')
        assert response.status_code == 200
        data = response.json()
        assert data['count'] == 1
        assert data['results'][0]['is_featured'] is True

    def test_game_detail_by_slug(self):
        response = self.client.get('/api/v1/games/test-game-1/')
        assert response.status_code == 200
        data = response.json()
        assert data['title'] == 'Test Game 1'

    def test_play_count_increment(self):
        response = self.client.post('/api/v1/games/test-game-1/play/')
        assert response.status_code == 200
        assert response.json()['play_count'] == 1

        response = self.client.post('/api/v1/games/test-game-1/play/')
        assert response.json()['play_count'] == 2

    def test_draft_detail_returns_404(self):
        response = self.client.get('/api/v1/games/draft-game/')
        assert response.status_code == 404
