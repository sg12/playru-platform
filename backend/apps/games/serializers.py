from rest_framework import serializers
from .models import Game


class GameListSerializer(serializers.ModelSerializer):
    class Meta:
        model = Game
        fields = [
            'id', 'title', 'slug', 'short_description', 'thumbnail',
            'max_players', 'min_players', 'play_count', 'active_players',
            'is_featured', 'tags', 'created_at',
        ]


class GameDetailSerializer(serializers.ModelSerializer):
    class Meta:
        model = Game
        fields = [
            'id', 'title', 'slug', 'description', 'short_description',
            'thumbnail', 'nakama_match_label', 'lua_module_name',
            'max_players', 'min_players', 'play_count', 'active_players',
            'status', 'is_featured', 'tags', 'created_at', 'updated_at',
        ]
