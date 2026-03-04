from rest_framework import serializers
from .models import UserProfile, GameSession


class UserProfileSerializer(serializers.ModelSerializer):
    class Meta:
        model = UserProfile
        fields = [
            'id', 'nakama_user_id', 'display_name', 'avatar_url',
            'auth_provider', 'external_id',
            'total_play_time_minutes', 'games_played', 'games_completed',
            'is_banned', 'created_at', 'last_seen',
        ]
        read_only_fields = ['id', 'created_at', 'last_seen']


class ProfileSyncSerializer(serializers.Serializer):
    nakama_user_id = serializers.CharField(max_length=100)
    display_name = serializers.CharField(max_length=80)
    avatar_url = serializers.URLField(required=False, default='', allow_blank=True)
    auth_provider = serializers.ChoiceField(
        choices=UserProfile.AuthProvider.choices,
        default=UserProfile.AuthProvider.GUEST,
    )
    external_id = serializers.CharField(max_length=100, required=False, default='')


class GameSessionSerializer(serializers.ModelSerializer):
    class Meta:
        model = GameSession
        fields = [
            'session_id', 'nakama_user_id', 'game', 'started_at', 'ended_at',
            'duration_seconds', 'score', 'completed', 'platform',
        ]
        read_only_fields = ['session_id', 'started_at']


class SessionStartSerializer(serializers.Serializer):
    nakama_user_id = serializers.CharField(max_length=100)
    game_slug = serializers.SlugField()
    platform = serializers.ChoiceField(
        choices=[('android', 'Android'), ('ios', 'iOS'), ('web', 'Web')],
        default='android',
    )


class SessionEndSerializer(serializers.Serializer):
    score = serializers.IntegerField(default=0)
    completed = serializers.BooleanField(default=False)
    duration_seconds = serializers.IntegerField(default=0)
