"""Tests for auto-publish: GameSubmission → Game при approve."""

import factory
import pytest
from django.contrib.auth.models import User
from django.test import Client, TestCase, override_settings
from rest_framework.test import APIClient

from apps.developer.models import DeveloperProfile, GameSubmission
from apps.games.models import Game
from apps.platform.admin_views import _publish_submission


class DeveloperProfileFactory(factory.django.DjangoModelFactory):
    class Meta:
        model = DeveloperProfile

    user = factory.SubFactory(
        'tests.test_auto_publish.UserFactory',
    )
    display_name = factory.Sequence(lambda n: f'Dev Studio {n}')


class UserFactory(factory.django.DjangoModelFactory):
    class Meta:
        model = User

    username = factory.Sequence(lambda n: f'dev-{n}')
    email = factory.Sequence(lambda n: f'dev{n}@test.com')
    password = factory.PostGenerationMethodCall('set_password', 'pass123')


class GameSubmissionFactory(factory.django.DjangoModelFactory):
    class Meta:
        model = GameSubmission

    developer = factory.SubFactory(DeveloperProfileFactory)
    title = factory.Sequence(lambda n: f'Submitted Game {n}')
    slug = factory.Sequence(lambda n: f'submitted-game-{n}')
    description = 'Test game description'
    genre = 'action'
    min_age = 6
    status = GameSubmission.Status.PENDING
    nakama_module_name = factory.Sequence(lambda n: f'module_{n}')


# --- Unit tests for _publish_submission ---

@pytest.mark.django_db
class TestPublishSubmission:
    def test_creates_game_on_publish(self):
        submission = GameSubmissionFactory(slug='pub-test-1')
        _publish_submission(submission)

        assert submission.status == 'published'
        assert submission.game is not None
        assert submission.game.slug == 'pub-test-1'
        assert submission.game.status == Game.Status.PUBLISHED

    def test_game_fields_match_submission(self):
        submission = GameSubmissionFactory(
            title='My Awesome Game',
            slug='awesome-game',
            description='A great game about testing',
            genre='puzzle',
            min_age=8,
            nakama_module_name='awesome_module',
        )
        _publish_submission(submission)

        game = submission.game
        assert game.title == 'My Awesome Game'
        assert game.description == 'A great game about testing'
        assert game.genre == 'puzzle'
        assert game.min_age == 8
        assert game.nakama_match_label == 'awesome_module'
        assert game.lua_module_name == 'awesome_module'

    def test_game_appears_in_catalog_api(self):
        submission = GameSubmissionFactory(slug='catalog-test')
        _publish_submission(submission)

        client = APIClient()
        response = client.get('/api/v1/games/')
        slugs = [g['slug'] for g in response.json()['results']]
        assert 'catalog-test' in slugs

    def test_game_detail_accessible(self):
        submission = GameSubmissionFactory(slug='detail-test')
        _publish_submission(submission)

        client = APIClient()
        response = client.get('/api/v1/games/detail-test/')
        assert response.status_code == 200
        assert response.json()['title'] == submission.title

    def test_updates_existing_game_on_reapprove(self):
        submission = GameSubmissionFactory(slug='reapprove-test', title='Version 1')
        _publish_submission(submission)
        game_id = submission.game.pk

        # Simulate re-submission with updated title
        submission.title = 'Version 2'
        submission.status = 'pending'
        submission.save()
        _publish_submission(submission)

        assert submission.game.pk == game_id  # same Game object
        submission.game.refresh_from_db()
        assert submission.game.title == 'Version 2'

    def test_short_description_truncated(self):
        long_desc = 'A' * 500
        submission = GameSubmissionFactory(description=long_desc)
        _publish_submission(submission)

        assert len(submission.game.short_description) <= 300

    def test_publish_does_not_affect_other_games(self):
        existing = Game.objects.create(
            title='Existing', slug='existing', status=Game.Status.PUBLISHED,
        )
        submission = GameSubmissionFactory(slug='new-one')
        _publish_submission(submission)

        existing.refresh_from_db()
        assert existing.status == Game.Status.PUBLISHED
        assert Game.objects.count() == 2


# --- Integration tests: moderation queue approve ---

@override_settings(ALLOWED_HOSTS=['*'])
class TestModerationApprove(TestCase):
    def setUp(self):
        self.admin = User.objects.create_superuser('admin', 'admin@test.com', 'admin123')
        self.client = Client()
        self.client.login(username='admin', password='admin123')

        dev_user = User.objects.create_user('dev', 'dev@test.com', 'pass123')
        self.profile = DeveloperProfile.objects.create(user=dev_user, display_name='Dev')

    def test_approve_via_moderation_queue(self):
        submission = GameSubmission.objects.create(
            developer=self.profile, title='Queue Game', slug='queue-game',
            description='Test', genre='action', status='pending',
        )
        response = self.client.post('/admin/moderation/queue/', {
            'submission_id': submission.pk,
            'action': 'approve',
        })
        self.assertEqual(response.status_code, 302)

        submission.refresh_from_db()
        self.assertEqual(submission.status, 'published')
        self.assertIsNotNone(submission.game)

        # Game should be in catalog
        game = Game.objects.get(slug='queue-game')
        self.assertEqual(game.status, 'published')
        self.assertEqual(game.title, 'Queue Game')

    def test_reject_does_not_create_game(self):
        submission = GameSubmission.objects.create(
            developer=self.profile, title='Reject Game', slug='reject-game',
            description='Test', genre='action', status='pending',
        )
        self.client.post('/admin/moderation/queue/', {
            'submission_id': submission.pk,
            'action': 'reject',
            'rejection_reason': 'Not ready',
        })
        submission.refresh_from_db()
        self.assertEqual(submission.status, 'rejected')
        self.assertIsNone(submission.game)
        self.assertFalse(Game.objects.filter(slug='reject-game').exists())


# --- Full flow: developer submits → moderator approves → game in catalog ---

@override_settings(ALLOWED_HOSTS=['*'])
class TestFullPublishFlow(TestCase):
    def setUp(self):
        # Developer
        self.dev_client = Client()
        self.dev_client.post('/dev/register/', {
            'username': 'flowdev',
            'email': 'flowdev@test.com',
            'display_name': 'Flow Developer',
            'password': 'pass123',
            'password_confirm': 'pass123',
        })

        # Admin
        self.admin = User.objects.create_superuser('admin', 'a@t.com', 'admin123')
        self.admin_client = Client()
        self.admin_client.login(username='admin', password='admin123')

    def test_developer_submit_to_catalog(self):
        # 1. Developer creates and submits game
        self.dev_client.post('/dev/games/new/', {
            'title': 'Flow Game',
            'slug': 'flow-game',
            'description': 'A full flow test game',
            'genre': 'puzzle',
            'min_age': '6',
            'submit': '',
        })
        submission = GameSubmission.objects.get(slug='flow-game')
        self.assertEqual(submission.status, 'pending')

        # 2. Admin approves
        self.admin_client.post('/admin/moderation/queue/', {
            'submission_id': submission.pk,
            'action': 'approve',
        })
        submission.refresh_from_db()
        self.assertEqual(submission.status, 'published')

        # 3. Game appears in public API
        api_client = APIClient()
        response = api_client.get('/api/v1/games/')
        slugs = [g['slug'] for g in response.json()['results']]
        self.assertIn('flow-game', slugs)

        # 4. Game detail works
        response = api_client.get('/api/v1/games/flow-game/')
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()['title'], 'Flow Game')
