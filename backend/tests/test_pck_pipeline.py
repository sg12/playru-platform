"""Tests for PCK upload pipeline: developer uploads .pck → approve → Game has pck_url."""

import hashlib

import pytest
from django.contrib.auth.models import User
from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import Client, TestCase, override_settings
from rest_framework.test import APIClient

from apps.developer.models import DeveloperProfile, GameSubmission
from apps.games.models import Game
from apps.platform.admin_views import _publish_submission


def _make_pck(content=b'GDPC\x00\x00fake-pck-content-for-testing'):
    """Create a fake .pck file for testing."""
    return SimpleUploadedFile('test.pck', content, content_type='application/octet-stream')


# --- API: PCK fields in game catalog ---

@pytest.mark.django_db
class TestGameCatalogPCKFields:
    def setup_method(self):
        self.client = APIClient()

    def test_builtin_game_has_null_pck_url(self):
        Game.objects.create(
            title='Builtin', slug='builtin', status='published',
        )
        response = self.client.get('/api/v1/games/')
        game = response.json()['results'][0]
        assert game['pck_url'] is None
        assert game['pck_hash'] == ''
        assert game['pck_size'] == 0
        assert game['pck_version'] == ''
        assert game['entry_scene'] == ''

    def test_pck_game_has_pck_url(self):
        game = Game.objects.create(
            title='PCK Game', slug='pck-game', status='published',
            pck_hash='abc123', pck_size=1024, pck_version='20260309',
            entry_scene='res://MyGame.tscn',
        )
        game.pck_file.save('pck-game.pck', _make_pck(), save=True)

        response = self.client.get('/api/v1/games/')
        data = response.json()['results'][0]
        assert data['pck_url'] is not None
        assert '/games/pck/pck-game' in data['pck_url']
        assert data['pck_url'].endswith('.pck')
        assert data['pck_hash'] == 'abc123'
        assert data['pck_size'] == 1024
        assert data['pck_version'] == '20260309'
        assert data['entry_scene'] == 'res://MyGame.tscn'

    def test_detail_endpoint_has_pck_fields(self):
        game = Game.objects.create(
            title='Detail PCK', slug='detail-pck', status='published',
            entry_scene='res://Main.tscn',
        )
        response = self.client.get('/api/v1/games/detail-pck/')
        data = response.json()
        assert 'pck_url' in data
        assert data['entry_scene'] == 'res://Main.tscn'


# --- _publish_submission with PCK ---

@pytest.mark.django_db
class TestPublishWithPCK:
    def _make_submission(self, **kwargs):
        user = User.objects.create_user(
            f'dev-{GameSubmission.objects.count()}',
            password='pass',
        )
        profile = DeveloperProfile.objects.create(user=user, display_name='Dev')
        defaults = dict(
            developer=profile, title='PCK Game',
            slug=f'pck-{GameSubmission.objects.count()}',
            description='Test', genre='action', status='pending',
        )
        defaults.update(kwargs)
        return GameSubmission.objects.create(**defaults)

    def test_publish_with_pck_copies_file(self):
        pck_content = b'GDPC\x00\x00test-pck-data-12345'
        submission = self._make_submission(slug='pck-copy-test')
        submission.pck_file.save('test.pck', _make_pck(pck_content), save=True)
        submission.entry_scene = 'res://Game.tscn'
        submission.save()

        _publish_submission(submission)

        game = submission.game
        assert game.pck_file
        assert game.pck_size == len(pck_content)
        assert game.pck_hash == hashlib.sha256(pck_content).hexdigest()
        assert game.pck_version  # auto-generated timestamp
        assert game.entry_scene == 'res://Game.tscn'

    def test_publish_without_pck(self):
        submission = self._make_submission(slug='no-pck-test')
        _publish_submission(submission)

        game = submission.game
        assert not game.pck_file
        assert game.pck_hash == ''
        assert game.pck_size == 0

    def test_pck_hash_is_correct_sha256(self):
        content = b'specific-content-for-hash-test'
        expected = hashlib.sha256(content).hexdigest()

        submission = self._make_submission(slug='hash-test')
        submission.pck_file.save('test.pck', _make_pck(content), save=True)
        _publish_submission(submission)

        assert submission.game.pck_hash == expected


# --- Full flow: developer uploads PCK → approve → visible in API ---

@override_settings(ALLOWED_HOSTS=['*'])
class TestPCKFullFlow(TestCase):
    def setUp(self):
        self.dev_client = Client()
        self.dev_client.post('/dev/register/', {
            'username': 'pckdev',
            'email': 'pckdev@test.com',
            'display_name': 'PCK Developer',
            'password': 'pass123',
            'password_confirm': 'pass123',
        })
        self.admin = User.objects.create_superuser('admin', 'a@t.com', 'admin123')
        self.admin_client = Client()
        self.admin_client.login(username='admin', password='admin123')

    def test_upload_pck_and_publish(self):
        pck_content = b'GDPC-full-flow-test-content'
        pck_file = _make_pck(pck_content)

        # 1. Developer submits game with PCK
        response = self.dev_client.post('/dev/games/new/', {
            'title': 'PCK Flow Game',
            'slug': 'pck-flow',
            'description': 'A game with PCK',
            'genre': 'action',
            'min_age': '6',
            'entry_scene': 'res://FlowGame.tscn',
            'pck_file': pck_file,
            'submit': '',
        })
        self.assertEqual(response.status_code, 302)
        submission = GameSubmission.objects.get(slug='pck-flow')
        self.assertEqual(submission.status, 'pending')
        self.assertTrue(submission.pck_file)
        self.assertEqual(submission.entry_scene, 'res://FlowGame.tscn')

        # 2. Admin approves
        self.admin_client.post('/admin/moderation/queue/', {
            'submission_id': submission.pk,
            'action': 'approve',
        })

        # 3. Game appears in API with PCK data
        api_client = APIClient()
        response = api_client.get('/api/v1/games/pck-flow/')
        self.assertEqual(response.status_code, 200)
        data = response.json()
        self.assertIsNotNone(data['pck_url'])
        self.assertIn('/games/pck/pck-flow', data['pck_url'])
        self.assertTrue(data['pck_url'].endswith('.pck'))
        self.assertEqual(data['pck_hash'], hashlib.sha256(pck_content).hexdigest())
        self.assertEqual(data['pck_size'], len(pck_content))
        self.assertEqual(data['entry_scene'], 'res://FlowGame.tscn')

    def test_submit_without_pck(self):
        response = self.dev_client.post('/dev/games/new/', {
            'title': 'No PCK Game',
            'slug': 'no-pck',
            'description': 'A game without PCK',
            'genre': 'puzzle',
            'min_age': '6',
            'submit': '',
        })
        self.assertEqual(response.status_code, 302)
        submission = GameSubmission.objects.get(slug='no-pck')
        self.assertFalse(submission.pck_file)

        # Approve
        self.admin_client.post('/admin/moderation/queue/', {
            'submission_id': submission.pk,
            'action': 'approve',
        })

        api_client = APIClient()
        response = api_client.get('/api/v1/games/no-pck/')
        data = response.json()
        self.assertIsNone(data['pck_url'])


# --- Form validation ---

@override_settings(ALLOWED_HOSTS=['*'])
class TestPCKFormValidation(TestCase):
    def setUp(self):
        self.client = Client()
        self.client.post('/dev/register/', {
            'username': 'formdev',
            'email': 'formdev@test.com',
            'display_name': 'Form Dev',
            'password': 'pass123',
            'password_confirm': 'pass123',
        })

    def test_oversized_pck_rejected(self):
        # 51 MB file should be rejected (limit is 50 MB)
        big_content = b'x' * (51 * 1024 * 1024)
        big_pck = SimpleUploadedFile('big.pck', big_content)

        response = self.client.post('/dev/games/new/', {
            'title': 'Big Game',
            'slug': 'big-game',
            'description': 'Too big',
            'genre': 'action',
            'min_age': '6',
            'pck_file': big_pck,
            'submit': '',
        })
        # Should stay on form (200), not redirect (302)
        self.assertEqual(response.status_code, 200)
        self.assertFalse(GameSubmission.objects.filter(slug='big-game').exists())
