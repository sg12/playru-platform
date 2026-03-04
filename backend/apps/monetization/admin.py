from django.contrib import admin
from .models import PlayCoinPackage, Order, Subscription


@admin.register(PlayCoinPackage)
class PackageAdmin(admin.ModelAdmin):
    list_display = ['name', 'coins', 'bonus_coins', 'price_rub', 'is_popular', 'is_active']
    list_filter = ['is_active', 'is_popular']
    ordering = ['sort_order']


@admin.register(Order)
class OrderAdmin(admin.ModelAdmin):
    list_display = ['id_short', 'order_type', 'status', 'amount_rub',
                    'coins_amount', 'created_at', 'paid_at']
    list_filter = ['status', 'order_type', 'payment_provider']
    search_fields = ['nakama_user_id', 'payment_id']
    date_hierarchy = 'created_at'
    readonly_fields = ['id', 'created_at', 'paid_at']

    def id_short(self, obj):
        return str(obj.id)[:8] + '...'
    id_short.short_description = 'ID'


@admin.register(Subscription)
class SubscriptionAdmin(admin.ModelAdmin):
    list_display = ['id', 'nakama_user_id', 'status', 'expires_at', 'auto_renew']
    list_filter = ['status', 'auto_renew']
    date_hierarchy = 'started_at'
