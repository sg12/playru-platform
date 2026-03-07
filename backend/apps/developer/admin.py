from django.contrib import admin

from .models import DeveloperProfile


@admin.register(DeveloperProfile)
class DeveloperProfileAdmin(admin.ModelAdmin):
    list_display = ('display_name', 'user', 'total_earnings', 'created_at')
    search_fields = ('display_name', 'user__username')
    readonly_fields = ('created_at',)


# GameSubmission зарегистрирован в apps.platform.admin (модерация)
