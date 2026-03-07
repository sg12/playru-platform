from django.contrib import admin

from .models import DeveloperApplication


@admin.register(DeveloperApplication)
class DeveloperApplicationAdmin(admin.ModelAdmin):
    list_display = ('name', 'email', 'status', 'created_at')
    list_filter = ('status', 'created_at')
    search_fields = ('name', 'email')
    readonly_fields = ('created_at',)
    actions = ['approve', 'reject']

    @admin.action(description='Одобрить выбранные заявки')
    def approve(self, request, queryset):
        queryset.update(status='approved')

    @admin.action(description='Отклонить выбранные заявки')
    def reject(self, request, queryset):
        queryset.update(status='rejected')
