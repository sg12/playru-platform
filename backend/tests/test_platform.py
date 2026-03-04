import factory
import pytest
from rest_framework.test import APIClient

from apps.platform.models import UserProfile


class UserProfileFactory(factory.django.DjangoModelFactory):
    class Meta:
        model = UserProfile

    nakama_user_id = factory.Sequence(lambda n: f'nakama-user-{n}')
    display_name = factory.Sequence(lambda n: f'Player {n}')
    auth_provider = UserProfile.AuthProvider.GUEST


@pytest.mark.django_db
class TestUserProfileModel:
    def test_create_profile(self):
        profile = UserProfileFactory()
        assert profile.pk is not None
        assert profile.display_name.startswith('Player')
        assert profile.games_played == 0

    def test_profile_str(self):
        profile = UserProfileFactory(display_name='Test', auth_provider='vk')
        assert str(profile) == 'Test (vk)'


@pytest.mark.django_db
class TestPlatformAPI:
    def setup_method(self):
        self.client = APIClient()

    def test_profile_sync_creates(self):
        response = self.client.post('/api/v1/profile/sync/', {
            'nakama_user_id': 'sync-test-1',
            'display_name': 'New Player',
            'auth_provider': 'guest',
        }, format='json')
        assert response.status_code == 201
        data = response.json()
        assert data['display_name'] == 'New Player'
        assert data['created'] is True

    def test_profile_sync_updates(self):
        self.client.post('/api/v1/profile/sync/', {
            'nakama_user_id': 'sync-test-2',
            'display_name': 'Original',
            'auth_provider': 'guest',
        }, format='json')
        response = self.client.post('/api/v1/profile/sync/', {
            'nakama_user_id': 'sync-test-2',
            'display_name': 'Updated',
            'auth_provider': 'vk',
        }, format='json')
        assert response.status_code == 200
        data = response.json()
        assert data['display_name'] == 'Updated'
        assert data['created'] is False

    def test_profile_get(self):
        UserProfileFactory(nakama_user_id='get-test-1', display_name='Getter')
        response = self.client.get('/api/v1/profile/get-test-1/')
        assert response.status_code == 200
        assert response.json()['nakama_user_id'] == 'get-test-1'

    def test_profile_get_404(self):
        response = self.client.get('/api/v1/profile/nonexistent/')
        assert response.status_code == 404

    def test_platform_health(self):
        response = self.client.get('/api/v1/platform/health/')
        assert response.status_code == 200
        data = response.json()
        assert data['status'] in ('ok', 'degraded')
        assert 'games_count' in data
        assert 'checks' in data
        assert 'database' in data['checks']
        assert 'version' in data
