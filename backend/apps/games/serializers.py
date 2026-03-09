from rest_framework import serializers
from .models import Game


class GameListSerializer(serializers.ModelSerializer):
    pck_url = serializers.SerializerMethodField()

    class Meta:
        model = Game
        fields = [
            'id', 'title', 'slug', 'short_description', 'thumbnail',
            'max_players', 'min_players', 'play_count', 'active_players',
            'is_featured', 'tags', 'created_at',
            'pck_url', 'pck_hash', 'pck_size', 'pck_version', 'entry_scene',
        ]

    def get_pck_url(self, obj):
        if obj.pck_file:
            request = self.context.get('request')
            if request:
                return request.build_absolute_uri(obj.pck_file.url)
            return obj.pck_file.url
        return None


class GameDetailSerializer(serializers.ModelSerializer):
    pck_url = serializers.SerializerMethodField()

    class Meta:
        model = Game
        fields = [
            'id', 'title', 'slug', 'description', 'short_description',
            'thumbnail', 'nakama_match_label', 'lua_module_name',
            'max_players', 'min_players', 'play_count', 'active_players',
            'status', 'is_featured', 'tags', 'created_at', 'updated_at',
            'pck_url', 'pck_hash', 'pck_size', 'pck_version', 'entry_scene',
        ]

    def get_pck_url(self, obj):
        if obj.pck_file:
            request = self.context.get('request')
            if request:
                return request.build_absolute_uri(obj.pck_file.url)
            return obj.pck_file.url
        return None
