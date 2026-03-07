from django.urls import path

from . import admin_views

urlpatterns = [
    path('queue/', admin_views.moderation_queue, name='moderation-queue'),
    path('stats/', admin_views.moderation_stats, name='moderation-stats'),
]
