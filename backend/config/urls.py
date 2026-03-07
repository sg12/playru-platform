from django.contrib import admin
from django.urls import include, path

from apps.platform.views_dashboard import PublicMetricsView, PitchDeckSnapshotView
from apps.monetization.views import (
    PackagesListView, CreateOrderView, OrderStatusView,
    YuKassaWebhookView, SubscriptionStatusView, RevenueAnalyticsView
)
urlpatterns = [
    path('admin/moderation/', include('apps.platform.admin_urls')),
    path('admin/', admin.site.urls),
    path('dev/', include('apps.developer.urls')),
    path('api/v1/games/', include('apps.games.urls')),
    path('api/v1/', include('apps.platform.urls')),
    path('api/v1/public/metrics/', PublicMetricsView.as_view(), name='public-metrics'),
    path('api/v1/public/pitch/', PitchDeckSnapshotView.as_view(), name='public-pitch'),
    path('api/v1/shop/packages/', PackagesListView.as_view(), name='shop-packages'),
    path('api/v1/shop/order/', CreateOrderView.as_view(), name='shop-create-order'),
    path('api/v1/shop/order/<uuid:order_id>/', OrderStatusView.as_view(), name='shop-order-status'),
    path('api/v1/shop/webhook/yukassa/', YuKassaWebhookView.as_view(), name='shop-webhook'),
    path('api/v1/shop/subscription/<str:nakama_user_id>/', SubscriptionStatusView.as_view(), name='shop-subscription'),
    path('api/v1/shop/analytics/', RevenueAnalyticsView.as_view(), name='shop-analytics'),
    path('', include('django_prometheus.urls')),
    path('', include('apps.store.urls')),
]
