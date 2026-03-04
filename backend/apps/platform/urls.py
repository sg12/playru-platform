from django.urls import path

from . import views

app_name = 'platform'

urlpatterns = [
    path('profile/sync/', views.ProfileSyncView.as_view(), name='profile-sync'),
    path('profile/<str:nakama_user_id>/', views.ProfileDetailView.as_view(), name='profile-detail'),
    path('platform/health/', views.PlatformHealthView.as_view(), name='platform-health'),
    path('sessions/start/', views.SessionStartView.as_view(), name='session-start'),
    path('sessions/<uuid:session_id>/end/', views.SessionEndView.as_view(), name='session-end'),
    path('stats/summary/', views.StatsSummaryView.as_view(), name='stats-summary'),
]
