import json
import uuid

from django.http import JsonResponse
from django.views import View
from django.utils import timezone
from django.views.decorators.csrf import csrf_exempt
from django.utils.decorators import method_decorator

from .models import PlayCoinPackage, Order, Subscription


class PackagesListView(View):
    """GET /api/v1/shop/packages/ — список пакетов PlayCoin."""

    def get(self, request):
        packages = PlayCoinPackage.objects.filter(is_active=True)
        return JsonResponse({
            'packages': [
                {
                    'slug': p.slug,
                    'name': p.name,
                    'coins': p.coins,
                    'bonus_coins': p.bonus_coins,
                    'total_coins': p.total_coins,
                    'price_rub': str(p.price_rub),
                    'is_popular': p.is_popular,
                    'price_per_coin': p.price_per_coin,
                }
                for p in packages
            ]
        })


@method_decorator(csrf_exempt, name='dispatch')
class CreateOrderView(View):
    """
    POST /api/v1/shop/order/
    Создать заказ на покупку PlayCoin.
    Body: {nakama_user_id, package_slug}
    """

    def post(self, request):
        try:
            data = json.loads(request.body)
        except Exception:
            return JsonResponse({'error': 'Invalid JSON'}, status=400)

        user_id = data.get('nakama_user_id')
        slug = data.get('package_slug')

        if not user_id or not slug:
            return JsonResponse(
                {'error': 'nakama_user_id and package_slug required'}, status=400)

        try:
            package = PlayCoinPackage.objects.get(slug=slug, is_active=True)
        except PlayCoinPackage.DoesNotExist:
            return JsonResponse({'error': 'Package not found'}, status=404)

        order = Order.objects.create(
            nakama_user_id=user_id,
            order_type=Order.OrderType.COINS,
            package=package,
            coins_amount=package.total_coins,
            amount_rub=package.price_rub,
            payment_provider='yukassa',
            payment_id=f'stub_{uuid.uuid4().hex[:16]}',
            payment_url=f'https://yookassa.ru/checkout/stub/{uuid.uuid4().hex}',
        )

        return JsonResponse({
            'order_id': str(order.id),
            'status': order.status,
            'amount_rub': str(order.amount_rub),
            'coins_amount': order.coins_amount,
            'payment_url': order.payment_url,
            'note': 'STUB: платёж не реальный, ЮKassa подключается после хостинга',
        }, status=201)


class OrderStatusView(View):
    """GET /api/v1/shop/order/<order_id>/ — статус заказа."""

    def get(self, request, order_id):
        try:
            order = Order.objects.get(id=order_id)
        except (Order.DoesNotExist, ValueError):
            return JsonResponse({'error': 'Order not found'}, status=404)

        return JsonResponse({
            'order_id': str(order.id),
            'status': order.status,
            'amount_rub': str(order.amount_rub),
            'coins_amount': order.coins_amount,
            'created_at': order.created_at.isoformat(),
            'paid_at': order.paid_at.isoformat() if order.paid_at else None,
        })


@method_decorator(csrf_exempt, name='dispatch')
class YuKassaWebhookView(View):
    """
    POST /api/v1/shop/webhook/yukassa/
    Заглушка для вебхука ЮKassa.
    """

    def post(self, request):
        try:
            data = json.loads(request.body)
        except Exception:
            return JsonResponse({'error': 'Invalid JSON'}, status=400)

        payment_id = data.get('object', {}).get('id', '')
        event = data.get('event', '')

        if event == 'payment.succeeded':
            try:
                order = Order.objects.get(payment_id=payment_id)
                order.status = Order.Status.PAID
                order.paid_at = timezone.now()
                order.save()
                return JsonResponse({'status': 'ok'})
            except Order.DoesNotExist:
                pass

        return JsonResponse({'status': 'ignored'})


class SubscriptionStatusView(View):
    """GET /api/v1/shop/subscription/<nakama_user_id>/ — статус подписки."""

    def get(self, request, nakama_user_id):
        sub = Subscription.objects.filter(
            nakama_user_id=nakama_user_id
        ).order_by('-started_at').first()

        if not sub or not sub.is_valid():
            return JsonResponse({
                'has_premium': False,
                'status': 'none',
            })

        return JsonResponse({
            'has_premium': True,
            'status': sub.status,
            'expires_at': sub.expires_at.isoformat(),
            'auto_renew': sub.auto_renew,
            'perks': [
                '2x PlayCoin за все игры',
                'Эксклюзивные скины',
                'Без рекламы (когда появится)',
                'Приоритетная поддержка',
            ]
        })


class RevenueAnalyticsView(View):
    """
    GET /api/v1/shop/analytics/
    Финансовая аналитика для питч-дека.
    """

    def get(self, request):
        from django.db.models import Sum, Count
        from datetime import timedelta

        now = timezone.now()
        last_30d = now - timedelta(days=30)
        last_7d = now - timedelta(days=7)

        paid_orders = Order.objects.filter(status=Order.Status.PAID)

        total_revenue = paid_orders.aggregate(
            total=Sum('amount_rub'))['total'] or 0
        revenue_30d = paid_orders.filter(
            paid_at__gte=last_30d).aggregate(
            total=Sum('amount_rub'))['total'] or 0
        revenue_7d = paid_orders.filter(
            paid_at__gte=last_7d).aggregate(
            total=Sum('amount_rub'))['total'] or 0

        from apps.platform.models import UserProfile
        total_users = UserProfile.objects.count()
        paying_users = paid_orders.values('nakama_user_id').distinct().count()
        conversion = round(paying_users / max(total_users, 1) * 100, 2)

        arpu = round(float(total_revenue) / max(paying_users, 1), 2)

        mau_target = 50000
        projected_paying = int(mau_target * (conversion / 100))
        projected_revenue_month = round(projected_paying * arpu, 0)

        popular_packages = list(
            paid_orders.values('package__name', 'package__price_rub')
            .annotate(count=Count('id'), revenue=Sum('amount_rub'))
            .order_by('-count')[:5]
        )

        return JsonResponse({
            'revenue': {
                'total_rub': float(total_revenue),
                'last_30d_rub': float(revenue_30d),
                'last_7d_rub': float(revenue_7d),
            },
            'users': {
                'total': total_users,
                'paying': paying_users,
                'conversion_pct': conversion,
                'arpu_rub': arpu,
            },
            'forecast_50k_mau': {
                'projected_paying_users': projected_paying,
                'projected_monthly_revenue_rub': projected_revenue_month,
                'note': f'При конверсии {conversion}% и ARPU {arpu}р'
            },
            'popular_packages': popular_packages,
            'subscriptions_active': Subscription.objects.filter(
                status=Subscription.Status.ACTIVE).count(),
        })
