import factory
import pytest
from django.test import TestCase
from rest_framework.test import APIClient

from apps.games.models import Game


class GameFactory(factory.django.DjangoModelFactory):
    class Meta:
        model = Game

    title = factory.Sequence(lambda n: f'Test Game {n}')
    slug = factory.Sequence(lambda n: f'test-game-{n}')
    description = 'Test description'
    short_description = 'Short desc'
    status = Game.Status.PUBLISHED


@pytest.mark.django_db
class TestGameModel:
    def test_create_game(self):
        game = GameFactory()
        assert game.pk is not None
        assert game.title.startswith('Test Game')
        assert game.play_count == 0

    def test_game_str(self):
        game = GameFactory(title='My Game')
        assert str(game) == 'My Game'


@pytest.mark.django_db
class TestGameAPI:
    def setup_method(self):
        self.client = APIClient()

    def test_list_games_returns_200(self):
        GameFactory()
        response = self.client.get('/api/v1/games/')
        assert response.status_code == 200
        data = response.json()
        assert 'count' in data
        assert 'results' in data

    def test_featured_returns_only_featured(self):
        GameFactory(is_featured=True)
        GameFactory(is_featured=False)
        response = self.client.get('/api/v1/games/featured/')
        assert response.status_code == 200
        data = response.json()
        for game in data['results']:
            assert game['is_featured'] is True

    def test_draft_not_in_api(self):
        GameFactory(status=Game.Status.DRAFT)
        response = self.client.get('/api/v1/games/')
        data = response.json()
        assert data['count'] == 0

    def test_play_increments_count(self):
        game = GameFactory(slug='play-test')
        assert game.play_count == 0
        response = self.client.post('/api/v1/games/play-test/play/')
        assert response.status_code == 200
        data = response.json()
        assert data['play_count'] == 1
