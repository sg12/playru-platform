from django.test import TestCase, Client, override_settings
from django.contrib.auth.models import User
from django.utils import timezone

from .models import DeveloperProfile, GameSubmission


ALLOWED_HOSTS_OVERRIDE = override_settings(ALLOWED_HOSTS=['*'])


@override_settings(ALLOWED_HOSTS=['*'])
class DeveloperRegistrationTest(TestCase):
    def test_register_creates_user_and_profile(self):
        client = Client()
        response = client.post('/dev/register/', {
            'username': 'devuser',
            'email': 'dev@example.com',
            'display_name': 'Dev Studio',
            'password': 'testpass123',
            'password_confirm': 'testpass123',
        })
        self.assertEqual(response.status_code, 302)
        user = User.objects.get(username='devuser')
        self.assertTrue(hasattr(user, 'developer_profile'))
        self.assertEqual(user.developer_profile.display_name, 'Dev Studio')
        # Auto-login check: session should exist
        self.assertIn('_auth_user_id', client.session)

    def test_register_password_mismatch(self):
        client = Client()
        response = client.post('/dev/register/', {
            'username': 'devuser',
            'email': 'dev@example.com',
            'display_name': 'Dev Studio',
            'password': 'testpass123',
            'password_confirm': 'wrongpass',
        })
        self.assertEqual(response.status_code, 200)
        self.assertFalse(User.objects.filter(username='devuser').exists())


@override_settings(ALLOWED_HOSTS=['*'])
class GameSubmissionTest(TestCase):
    def setUp(self):
        self.user = User.objects.create_user('dev', 'dev@test.com', 'pass123')
        self.profile = DeveloperProfile.objects.create(user=self.user, display_name='Dev')
        self.client = Client()
        self.client.login(username='dev', password='pass123')

    def test_create_draft(self):
        response = self.client.post('/dev/games/new/', {
            'title': 'My Game',
            'slug': 'my-game',
            'description': 'A test game',
            'genre': 'action',
            'min_age': '6',
            'draft': '',
        })
        self.assertEqual(response.status_code, 302)
        game = GameSubmission.objects.get(slug='my-game')
        self.assertEqual(game.status, 'draft')
        self.assertIsNone(game.submitted_at)

    def test_submit_for_moderation(self):
        response = self.client.post('/dev/games/new/', {
            'title': 'My Game 2',
            'slug': 'my-game-2',
            'description': 'A test game',
            'genre': 'puzzle',
            'min_age': '6',
            'submit': '',
        })
        self.assertEqual(response.status_code, 302)
        game = GameSubmission.objects.get(slug='my-game-2')
        self.assertEqual(game.status, 'pending')
        self.assertIsNotNone(game.submitted_at)

    def test_edit_only_draft_or_rejected(self):
        game = GameSubmission.objects.create(
            developer=self.profile, title='G', slug='g',
            description='d', genre='action', status='pending',
        )
        response = self.client.get(f'/dev/games/{game.pk}/edit/')
        # Should redirect since status is pending
        self.assertEqual(response.status_code, 302)

    def test_edit_draft_allowed(self):
        game = GameSubmission.objects.create(
            developer=self.profile, title='G', slug='g2',
            description='d', genre='action', status='draft',
        )
        response = self.client.get(f'/dev/games/{game.pk}/edit/')
        self.assertEqual(response.status_code, 200)


@override_settings(ALLOWED_HOSTS=['*'])
class PagesRenderTest(TestCase):
    def setUp(self):
        self.user = User.objects.create_user('dev', 'dev@test.com', 'pass123')
        self.profile = DeveloperProfile.objects.create(user=self.user, display_name='Dev')
        self.client = Client()
        self.client.login(username='dev', password='pass123')

    def test_dashboard(self):
        self.assertEqual(self.client.get('/dev/dashboard/').status_code, 200)

    def test_games_list(self):
        self.assertEqual(self.client.get('/dev/games/').status_code, 200)

    def test_game_create(self):
        self.assertEqual(self.client.get('/dev/games/new/').status_code, 200)

    def test_profile(self):
        self.assertEqual(self.client.get('/dev/profile/').status_code, 200)

    def test_game_detail(self):
        game = GameSubmission.objects.create(
            developer=self.profile, title='G', slug='g',
            description='d', genre='action',
        )
        self.assertEqual(self.client.get(f'/dev/games/{game.pk}/').status_code, 200)

    def test_login_page(self):
        client = Client()
        self.assertEqual(client.get('/dev/login/').status_code, 200)

    def test_register_page(self):
        client = Client()
        self.assertEqual(client.get('/dev/register/').status_code, 200)

    def test_pages_require_login(self):
        client = Client()
        for url in ['/dev/dashboard/', '/dev/games/', '/dev/games/new/', '/dev/profile/']:
            response = client.get(url)
            self.assertEqual(response.status_code, 302, f'{url} should require login')
            self.assertIn('/dev/login/', response.url)
