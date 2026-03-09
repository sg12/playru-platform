"""Tests for Developer Guide page and game stats in dashboard."""

import factory
import pytest
from django.contrib.auth.models import User
from django.test import Client, TestCase, override_settings

from apps.developer.models import DeveloperProfile, GameSubmission
from apps.games.models import Game
from apps.platform.models import GameSession


@override_settings(ALLOWED_HOSTS=['*'])
class TestDeveloperGuide(TestCase):
    def setUp(self):
        self.user = User.objects.create_user('dev', 'dev@test.com', 'pass123')
        self.profile = DeveloperProfile.objects.create(user=self.user, display_name='Dev')
        self.client = Client()
        self.client.login(username='dev', password='pass123')

    def test_guide_page_loads(self):
        response = self.client.get('/dev/guide/')
        self.assertEqual(response.status_code, 200)

    def test_guide_requires_login(self):
        client = Client()
        response = client.get('/dev/guide/')
        self.assertEqual(response.status_code, 302)
        self.assertIn('/dev/login/', response.url)

    def test_guide_contains_api_reference(self):
        response = self.client.get('/dev/guide/')
        content = response.content.decode()
        self.assertIn('Platform API Reference', content)
        self.assertIn('/sessions/start/', content)
        self.assertIn('/leaderboard/', content)

    def test_guide_contains_quick_start(self):
        response = self.client.get('/dev/guide/')
        content = response.content.decode()
        self.assertIn('Quick Start', content)

    def test_guide_link_in_navbar(self):
        response = self.client.get('/dev/dashboard/')
        content = response.content.decode()
        self.assertIn('/dev/guide/', content)
        self.assertIn('Guide', content)


@override_settings(ALLOWED_HOSTS=['*'])
class TestGameDetailStats(TestCase):
    def setUp(self):
        self.user = User.objects.create_user('dev', 'dev@test.com', 'pass123')
        self.profile = DeveloperProfile.objects.create(user=self.user, display_name='Dev')
        self.client = Client()
        self.client.login(username='dev', password='pass123')

    def test_no_stats_for_draft(self):
        submission = GameSubmission.objects.create(
            developer=self.profile, title='Draft', slug='draft',
            description='d', genre='action', status='draft',
        )
        response = self.client.get(f'/dev/games/{submission.pk}/')
        self.assertEqual(response.status_code, 200)
        self.assertNotContains(response, 'Статистика игры')

    def test_stats_shown_for_published(self):
        game = Game.objects.create(
            title='Published', slug='published', status='published',
            play_count=42,
        )
        submission = GameSubmission.objects.create(
            developer=self.profile, title='Published', slug='published',
            description='d', genre='action', status='published', game=game,
        )
        # Add some sessions
        GameSession.objects.create(
            game=game, nakama_user_id='test-user', score=100, duration_seconds=60,
        )

        response = self.client.get(f'/dev/games/{submission.pk}/')
        self.assertEqual(response.status_code, 200)
        self.assertContains(response, 'Статистика игры')
        self.assertContains(response, '42')  # play_count

    def test_stats_with_multiple_sessions(self):
        game = Game.objects.create(
            title='Multi', slug='multi-sess', status='published',
        )
        submission = GameSubmission.objects.create(
            developer=self.profile, title='Multi', slug='multi-sess',
            description='d', genre='action', status='published', game=game,
        )
        GameSession.objects.create(
            game=game, nakama_user_id='u1', score=100, duration_seconds=3600,
        )
        GameSession.objects.create(
            game=game, nakama_user_id='u2', score=200, duration_seconds=7200,
        )

        response = self.client.get(f'/dev/games/{submission.pk}/')
        self.assertEqual(response.status_code, 200)
        content = response.content.decode()
        self.assertIn('Сессий', content)
        self.assertIn('Время игры', content)
