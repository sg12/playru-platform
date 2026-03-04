from django.contrib import admin

from .models import UserProfile, GameSession, PlatformStats


@admin.register(UserProfile)
class UserProfileAdmin(admin.ModelAdmin):
    list_display = ('display_name', 'auth_provider', 'games_played', 'is_banned', 'last_seen')
    list_filter = ('auth_provider', 'is_banned')
    search_fields = ('display_name', 'nakama_user_id')
    readonly_fields = ('created_at', 'last_seen', 'total_play_time_minutes')


@admin.register(GameSession)
class GameSessionAdmin(admin.ModelAdmin):
    list_display = ('session_id', 'nakama_user_id', 'game', 'platform', 'score', 'completed', 'started_at', 'duration_seconds')
    list_filter = ('platform', 'completed', 'game', 'started_at')
    search_fields = ('nakama_user_id', 'session_id')
    readonly_fields = ('session_id', 'started_at')
    date_hierarchy = 'started_at'


@admin.register(PlatformStats)
class PlatformStatsAdmin(admin.ModelAdmin):
    list_display = ('date', 'dau', 'new_users', 'total_sessions', 'total_playtime_hours', 'revenue_rub')
    list_filter = ('date',)
    readonly_fields = ('date',)
    date_hierarchy = 'date'
