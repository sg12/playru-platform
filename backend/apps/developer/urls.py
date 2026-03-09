from django.urls import path

from . import views

app_name = 'developer'

urlpatterns = [
    path('register/', views.register_view, name='register'),
    path('login/', views.login_view, name='login'),
    path('logout/', views.logout_view, name='logout'),
    path('dashboard/', views.dashboard_view, name='dashboard'),
    path('games/', views.games_list_view, name='games_list'),
    path('games/new/', views.game_create_view, name='game_create'),
    path('games/<int:game_id>/', views.game_detail_view, name='game_detail'),
    path('games/<int:game_id>/edit/', views.game_edit_view, name='game_edit'),
    path('guide/', views.guide_view, name='guide'),
    path('profile/', views.profile_view, name='profile'),
]
