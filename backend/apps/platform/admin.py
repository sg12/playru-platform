from django.contrib import admin
from django.contrib.auth import get_user_model
from django.contrib.auth.admin import UserAdmin
from django.utils import timezone

from .models import UserProfile, GameSession, PlatformStats

try:
    from apps.developer.models import DeveloperProfile, GameSubmission
except ImportError:
    DeveloperProfile = None
    GameSubmission = None

# --- Брендинг ---
admin.site.site_header = "PlayRU Platform"
admin.site.site_title = "PlayRU Admin"
admin.site.index_title = "Управление платформой"


# --- Platform models ---
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


# --- GameSubmission (модерация) ---
if GameSubmission is not None:
    @admin.register(GameSubmission)
    class GameSubmissionModerationAdmin(admin.ModelAdmin):
        list_display = ('title', 'developer_display_name', 'genre', 'status', 'submitted_at')
        list_filter = ('status', 'genre')
        search_fields = ('title', 'developer__user__username')
        readonly_fields = ('developer', 'submitted_at', 'created_at')
        actions = ('approve_selected', 'reject_selected')

        @admin.display(description='Разработчик')
        def developer_display_name(self, obj):
            return obj.developer.display_name

        @admin.action(description='Одобрить выбранные игры')
        def approve_selected(self, request, queryset):
            from .admin_views import _publish_submission
            count = 0
            for submission in queryset:
                _publish_submission(submission)
                count += 1
            self.message_user(request, f'{count} игр(а) одобрено и опубликовано.')

        @admin.action(description='Отклонить выбранные игры')
        def reject_selected(self, request, queryset):
            if 'apply' in request.POST:
                reason = request.POST.get('rejection_reason', '')
                updated = queryset.update(
                    status='rejected',
                    rejection_reason=reason,
                )
                self.message_user(request, f'{updated} игр(а) отклонено.')
                return None

            from django.template.response import TemplateResponse
            return TemplateResponse(
                request,
                'admin/moderation/reject_form.html',
                context={
                    'title': 'Отклонение игр',
                    'queryset': queryset,
                    'action_checkbox_name': admin.helpers.ACTION_CHECKBOX_NAME,
                    'opts': self.model._meta,
                },
            )


# --- DeveloperProfile inline в UserAdmin ---
if DeveloperProfile is not None:
    class DeveloperProfileInline(admin.StackedInline):
        model = DeveloperProfile
        can_delete = False
        verbose_name = "Профиль разработчика"
        verbose_name_plural = "Профиль разработчика"

    User = get_user_model()
    try:
        admin.site.unregister(User)
    except admin.sites.NotRegistered:
        pass

    @admin.register(User)
    class CustomUserAdmin(UserAdmin):
        inlines = list(UserAdmin.inlines) + [DeveloperProfileInline]
