from django.contrib import admin

from .models import Game, GameRating


@admin.register(Game)
class GameAdmin(admin.ModelAdmin):
    list_display = ['title', 'slug', 'status', 'genre', 'play_count',
                    'avg_rating', 'ratings_count', 'created_at']
    list_filter = ['status', 'genre', 'is_featured']
    search_fields = ['title', 'slug', 'description']
    readonly_fields = ['play_count', 'avg_rating', 'ratings_count']
    prepopulated_fields = {'slug': ('title',)}
    ordering = ['-play_count']


@admin.register(GameRating)
class GameRatingAdmin(admin.ModelAdmin):
    list_display = ['game', 'stars', 'review_short', 'is_approved', 'created_at']
    list_filter = ['stars', 'is_approved', 'game']
    search_fields = ['review', 'nakama_user_id']
    date_hierarchy = 'created_at'
    actions = ['approve_selected', 'reject_selected']

    def review_short(self, obj):
        return obj.review[:60] + '...' if len(obj.review) > 60 else obj.review
    review_short.short_description = 'Отзыв'

    def approve_selected(self, request, queryset):
        queryset.update(is_approved=True)
    approve_selected.short_description = 'Одобрить выбранные'

    def reject_selected(self, request, queryset):
        queryset.update(is_approved=False)
    reject_selected.short_description = 'Отклонить выбранные'
