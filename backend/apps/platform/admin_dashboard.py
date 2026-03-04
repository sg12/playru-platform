"""
Кастомный Django Admin с дашбордом — для демонстрации инвесторам.
"""
from django.contrib import admin
from django.contrib.admin import AdminSite
from django.urls import path
from django.http import JsonResponse
from django.utils import timezone
from datetime import timedelta
from django.db.models import Sum


class PlayRUAdminSite(AdminSite):
    site_header = 'PlayRU — Администрирование'
    site_title = 'PlayRU Admin'
    index_title = 'Панель управления'

    def get_urls(self):
        urls = super().get_urls()
        custom = [
            path('dashboard/metrics/', self.admin_view(self.metrics_api)),
        ]
        return custom + urls

    def metrics_api(self, request):
        """API для дашборда."""
        from apps.platform.models import UserProfile
        from apps.games.models import Game
        from apps.monetization.models import Order

        now = timezone.now()
        dau = UserProfile.objects.filter(
            last_seen__gte=now - timedelta(hours=24)).count()
        mau = UserProfile.objects.filter(
            last_seen__gte=now - timedelta(days=30)).count()
        total = UserProfile.objects.count()
        revenue = Order.objects.filter(
            status='paid').aggregate(
            t=Sum('amount_rub'))['t'] or 0

        return JsonResponse({
            'dau': dau, 'mau': mau, 'total_users': total,
            'games': Game.objects.filter(status='published').count(),
            'revenue_rub': float(revenue),
            'retention': round(dau / max(total, 1) * 100, 1),
        })


playru_admin = PlayRUAdminSite(name='playru_admin')
