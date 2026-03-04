from django.urls import path

from . import views
from apps.platform.views import GameLeaderboardView

app_name = 'games'

urlpatterns = [
    path('', views.GameListView.as_view(), name='game-list'),
    path('featured/', views.GameFeaturedView.as_view(), name='game-featured'),
    path('<slug:slug>/', views.GameDetailView.as_view(), name='game-detail'),
    path('<slug:slug>/play/', views.GamePlayView.as_view(), name='game-play'),
    path('<slug:slug>/rate/', views.GameRateView.as_view(), name='game-rate'),
    path('<slug:slug>/reviews/', views.GameReviewsView.as_view(), name='game-reviews'),
    path('<slug:slug>/leaderboard/', GameLeaderboardView.as_view(), name='game-leaderboard'),
]
