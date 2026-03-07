from django.urls import path

from . import views

app_name = 'store'

urlpatterns = [
    path('', views.home, name='home'),
    path('games/<slug:slug>/', views.game_detail, name='game_detail'),
    path('download/', views.download, name='download'),
    path('developers/apply/', views.developer_apply, name='developer_apply'),
    path('developers/apply/success/', views.apply_success, name='apply_success'),
]
