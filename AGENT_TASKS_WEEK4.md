# AGENT 1 — playru-platform — НЕДЕЛЯ 4
## Монетизация: пакеты PlayCoin, подписка Premium, ЮKassa заглушки

> Продолжаем в playru-platform. Все предыдущие задачи выполнены.
> Цель недели: полная модель монетизации готова к подключению ЮKassa
> как только появится хостинг и юридическое лицо.
> После каждой задачи — приёмочные тесты. Стоп после ФИНАЛЬНОЙ ПРИЁМКИ.

---

## ЗАДАЧА 1 — Django: модели монетизации

Создай `backend/apps/monetization/` — новое приложение:

```bash
cd backend
python manage.py startapp monetization apps/monetization
```

**`backend/apps/monetization/models.py`**:
```python
from django.db import models
import uuid


class PlayCoinPackage(models.Model):
    """Пакеты PlayCoin для покупки за рубли."""

    slug = models.SlugField(unique=True)
    name = models.CharField(max_length=80)
    coins = models.PositiveIntegerField()
    bonus_coins = models.PositiveIntegerField(default=0)
    price_rub = models.DecimalField(max_digits=8, decimal_places=2)
    is_popular = models.BooleanField(default=False)
    is_active = models.BooleanField(default=True)
    sort_order = models.PositiveSmallIntegerField(default=0)

    class Meta:
        ordering = ['sort_order']
        verbose_name = 'Пакет PlayCoin'
        verbose_name_plural = 'Пакеты PlayCoin'

    def __str__(self):
        return f'{self.name} — {self.total_coins} монет за {self.price_rub}₽'

    @property
    def total_coins(self):
        return self.coins + self.bonus_coins

    @property
    def price_per_coin(self):
        return round(float(self.price_rub) / self.total_coins, 4)


class Subscription(models.Model):
    """Подписка PlayRU Premium."""

    class Status(models.TextChoices):
        ACTIVE = 'active', 'Активна'
        CANCELLED = 'cancelled', 'Отменена'
        EXPIRED = 'expired', 'Истекла'
        TRIAL = 'trial', 'Пробная'

    id = models.UUIDField(primary_key=True, default=uuid.uuid4)
    nakama_user_id = models.CharField(max_length=100, db_index=True)
    status = models.CharField(max_length=20, choices=Status.choices,
                               default=Status.TRIAL)
    started_at = models.DateTimeField(auto_now_add=True)
    expires_at = models.DateTimeField()
    cancelled_at = models.DateTimeField(null=True, blank=True)
    price_rub = models.DecimalField(max_digits=8, decimal_places=2,
                                     default=149.00)
    auto_renew = models.BooleanField(default=True)

    class Meta:
        verbose_name = 'Подписка Premium'

    def is_valid(self):
        from django.utils import timezone
        return (self.status in [self.Status.ACTIVE, self.Status.TRIAL]
                and self.expires_at > timezone.now())


class Order(models.Model):
    """Заказ на покупку PlayCoin или подписки."""

    class Status(models.TextChoices):
        PENDING = 'pending', 'Ожидает оплаты'
        PAID = 'paid', 'Оплачен'
        FAILED = 'failed', 'Ошибка'
        REFUNDED = 'refunded', 'Возврат'
        CANCELLED = 'cancelled', 'Отменён'

    class OrderType(models.TextChoices):
        COINS = 'coins', 'Пакет PlayCoin'
        SUBSCRIPTION = 'subscription', 'Подписка Premium'

    id = models.UUIDField(primary_key=True, default=uuid.uuid4)
    nakama_user_id = models.CharField(max_length=100, db_index=True)
    order_type = models.CharField(max_length=20, choices=OrderType.choices)
    status = models.CharField(max_length=20, choices=Status.choices,
                               default=Status.PENDING)

    # Что покупается
    package = models.ForeignKey(PlayCoinPackage, on_delete=models.SET_NULL,
                                  null=True, blank=True)
    coins_amount = models.PositiveIntegerField(default=0)
    amount_rub = models.DecimalField(max_digits=8, decimal_places=2)

    # Платёжная система
    payment_provider = models.CharField(max_length=30, default='yukassa')
    payment_id = models.CharField(max_length=200, blank=True)
    payment_url = models.URLField(blank=True)

    created_at = models.DateTimeField(auto_now_add=True)
    paid_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        verbose_name = 'Заказ'
        ordering = ['-created_at']
        indexes = [
            models.Index(fields=['nakama_user_id', 'status']),
            models.Index(fields=['payment_id']),
        ]

    def __str__(self):
        return f'Order {self.id} — {self.get_status_display()} — {self.amount_rub}₽'
```

### Приёмочные тесты задачи 1:
```bash
cd backend
python manage.py makemigrations monetization
python manage.py migrate && echo "OK: migrations"
python manage.py check && echo "OK: Django check"

python3 -c "
import django, os
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'config.settings.development')
django.setup()
from apps.monetization.models import PlayCoinPackage, Order, Subscription
print('OK: PlayCoinPackage model')
print('OK: Order model')
print('OK: Subscription model')
p = PlayCoinPackage(coins=100, bonus_coins=20, price_rub=49)
assert p.total_coins == 120, f'Expected 120, got {p.total_coins}'
print('OK: total_coins property works')
"
```

---

## ЗАДАЧА 2 — Seed пакетов и API монетизации

**Команда seed_monetization**:

Создай `backend/apps/monetization/management/commands/seed_monetization.py`:
```python
from django.core.management.base import BaseCommand
from apps.monetization.models import PlayCoinPackage


class Command(BaseCommand):
    help = 'Создать стартовые пакеты PlayCoin'

    def handle(self, *args, **options):
        packages = [
            {
                'slug': 'starter',
                'name': '💎 Стартовый',
                'coins': 100,
                'bonus_coins': 0,
                'price_rub': '49.00',
                'is_popular': False,
                'sort_order': 1,
            },
            {
                'slug': 'popular',
                'name': '💎💎 Популярный',
                'coins': 250,
                'bonus_coins': 50,
                'price_rub': '99.00',
                'is_popular': True,
                'sort_order': 2,
            },
            {
                'slug': 'mega',
                'name': '💎💎💎 Мега',
                'coins': 700,
                'bonus_coins': 300,
                'price_rub': '299.00',
                'is_popular': False,
                'sort_order': 3,
            },
            {
                'slug': 'ultra',
                'name': '👑 Ультра',
                'coins': 2000,
                'bonus_coins': 1000,
                'price_rub': '799.00',
                'is_popular': False,
                'sort_order': 4,
            },
        ]
        for p in packages:
            obj, created = PlayCoinPackage.objects.update_or_create(
                slug=p['slug'], defaults=p)
            status = 'создан' if created else 'обновлён'
            self.stdout.write(
                f"  {obj.name}: {obj.total_coins} монет за {obj.price_rub}₽ [{status}]")
        self.stdout.write(self.style.SUCCESS(
            f'\nОК: {PlayCoinPackage.objects.count()} пакетов в базе'))
```

**API endpoints** в `backend/apps/monetization/views.py`:

```python
from django.http import JsonResponse
from django.views import View
from django.utils import timezone
from datetime import timedelta
import uuid
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


class CreateOrderView(View):
    """
    POST /api/v1/shop/order/
    Создать заказ на покупку PlayCoin.
    Body: {nakama_user_id, package_slug}
    """

    def post(self, request):
        import json
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
            # Заглушка — реальный payment_id придёт от ЮKassa
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


class YuKassaWebhookView(View):
    """
    POST /api/v1/shop/webhook/yukassa/
    Заглушка для вебхука ЮKassa.
    В production: проверяет подпись, обновляет статус, начисляет монеты через Nakama.
    """

    def post(self, request):
        import json
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
                # TODO: начислить монеты через Nakama API
                # nakama_client.rpc('economy/add_coins', {
                #     'user_id': order.nakama_user_id,
                #     'amount': order.coins_amount,
                #     'reason': f'purchase_{order.id}'
                # })
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
```

Добавь в `backend/config/urls.py`:
```python
from apps.monetization.views import (
    PackagesListView, CreateOrderView, OrderStatusView,
    YuKassaWebhookView, SubscriptionStatusView
)

urlpatterns += [
    path('api/v1/shop/packages/', PackagesListView.as_view()),
    path('api/v1/shop/order/', CreateOrderView.as_view()),
    path('api/v1/shop/order/<uuid:order_id>/', OrderStatusView.as_view()),
    path('api/v1/shop/webhook/yukassa/', YuKassaWebhookView.as_view()),
    path('api/v1/shop/subscription/<str:nakama_user_id>/', SubscriptionStatusView.as_view()),
]
```

Зарегистрируй в admin с list_display и фильтрами.

### Приёмочные тесты задачи 2:
```bash
cd backend
python manage.py seed_monetization && echo "OK: seed packages"

python manage.py runserver &
sleep 3

# Список пакетов:
curl -sf http://localhost:8000/api/v1/shop/packages/ | python3 -c "
import sys, json
d = json.load(sys.stdin)
pkgs = d['packages']
assert len(pkgs) >= 4, f'Expected 4 packages, got {len(pkgs)}'
popular = [p for p in pkgs if p['is_popular']]
assert len(popular) >= 1, 'Expected at least 1 popular package'
print(f'OK: {len(pkgs)} packages, {len(popular)} popular')
for p in pkgs:
    print(f'  {p[\"name\"]}: {p[\"total_coins\"]} монет за {p[\"price_rub\"]}₽')
"

# Создать заказ:
ORDER_ID=$(curl -sf -X POST http://localhost:8000/api/v1/shop/order/ \
  -H "Content-Type: application/json" \
  -d '{"nakama_user_id":"test-user-123","package_slug":"popular"}' \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['order_id'])")
echo "OK: Order created: $ORDER_ID"

# Статус заказа:
curl -sf "http://localhost:8000/api/v1/shop/order/$ORDER_ID/" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['status'] == 'pending'
assert d['coins_amount'] == 300  # 250 + 50 bonus
print('OK: Order status:', d['status'], '| coins:', d['coins_amount'])
"

# Подписка (нет):
curl -sf http://localhost:8000/api/v1/shop/subscription/test-user-123/ | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['has_premium'] == False
print('OK: No subscription (expected)')
"

# Тесты:
pytest tests/ -v -k "monetiz or shop or order" --tb=short
kill %1
```

---

## ЗАДАЧА 3 — Nakama: Premium бонусы и множитель монет

Создай `nakama/modules/premium.lua`:

```lua
-- PlayRU Premium — бонусы для подписчиков
local nk = require("nakama")

local PREMIUM_MULTIPLIER = 2.0   -- удвоение монет
local PREMIUM_DAILY_BONUS = 150  -- вместо 50

-- Проверить есть ли Premium (через Django API)
-- В production: проверяем по storage или django API
local function has_premium(user_id)
    local objects = nk.storage_read({
        {collection = "premium", key = "subscription", user_id = user_id}
    })
    if #objects == 0 then return false end
    local data = nk.json_decode(objects[1].value)
    if not data or not data.expires_at then return false end
    return data.expires_at > nk.time()
end

-- RPC: Активировать Premium (вызывается после успешной оплаты)
local function activate_premium(context, payload)
    local data = nk.json_decode(payload)
    if not data or not data.days then error("Missing days") end

    local user_id = context.user_id
    local days = math.min(data.days or 30, 365)
    local expires_at = nk.time() + days * 86400 * 1000  -- миллисекунды

    nk.storage_write({{
        collection = "premium",
        key = "subscription",
        user_id = user_id,
        value = nk.json_encode({
            activated_at = nk.time(),
            expires_at = expires_at,
            days = days
        }),
        permission_read = 1,
        permission_write = 0
    }})

    -- Уведомление
    nk.notifications_send({{
        user_id = user_id,
        subject = "👑 PlayRU Premium активирован!",
        content = {
            message = "Premium активен на " .. days .. " дней. Монеты x2!",
            expires_days = days
        },
        code = 10,
        sender_id = "00000000-0000-0000-0000-000000000000",
        persistent = true
    }})

    nk.logger_info("Premium activated: " .. user_id .. " for " .. days .. " days")

    return nk.json_encode({
        success = true,
        expires_at = expires_at,
        days = days,
        perks = {"2x монеты", "Ежедневный бонус x3", "Эксклюзивные скины"}
    })
end

-- RPC: Статус Premium
local function premium_status(context, payload)
    local user_id = context.user_id
    local is_premium = has_premium(user_id)
    local expires_at = nil

    if is_premium then
        local objects = nk.storage_read({{
            collection = "premium", key = "subscription", user_id = user_id
        }})
        if #objects > 0 then
            local data = nk.json_decode(objects[1].value)
            expires_at = data.expires_at
        end
    end

    return nk.json_encode({
        has_premium = is_premium,
        expires_at = expires_at,
        multiplier = is_premium and PREMIUM_MULTIPLIER or 1.0,
        daily_bonus = is_premium and PREMIUM_DAILY_BONUS or 50
    })
end

-- RPC: Начислить монеты с учётом Premium множителя
-- Используется всеми игровыми модулями
local function award_coins(context, payload)
    local data = nk.json_decode(payload)
    if not data or not data.amount then error("Missing amount") end

    local user_id = context.user_id
    local base_amount = math.min(data.amount, 500)
    local reason = data.reason or "game_reward"

    local multiplier = has_premium(user_id) and PREMIUM_MULTIPLIER or 1.0
    local final_amount = math.floor(base_amount * multiplier)

    nk.wallet_update(user_id, {playcoin = final_amount},
        {source = reason, base = base_amount, multiplier = multiplier}, true)

    return nk.json_encode({
        success = true,
        base_amount = base_amount,
        multiplier = multiplier,
        final_amount = final_amount,
        is_premium = multiplier > 1.0
    })
end

nk.register_rpc(activate_premium, "premium/activate")
nk.register_rpc(premium_status, "premium/status")
nk.register_rpc(award_coins, "economy/award_coins")

-- Экспортируем has_premium для других модулей
return {has_premium = has_premium, MULTIPLIER = PREMIUM_MULTIPLIER}
```

Обнови `nakama/modules/economy.lua` — суточная награда учитывает Premium:
```lua
local premium = require("premium")
-- В claim_daily_reward:
local amount = premium.has_premium(user_id) and 150 or REWARDS.daily_login
```

Добавь в `nakama/modules/init.lua`:
```lua
require("premium")
```

### Приёмочные тесты задачи 3:
```bash
docker compose up -d && sleep 20

AUTH=$(curl -sf -X POST \
  "http://localhost:7350/v2/account/authenticate/device?create=true&username=prem_$$" \
  -u "playru-server-key:" -H "Content-Type: application/json" \
  -d '{"id":"premium-test-'$$'"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

# Статус без Premium:
curl -sf -X POST "http://localhost:7350/v2/rpc/premium%2Fstatus" \
  -H "Authorization: Bearer $AUTH" -d '{}' | python3 -c "
import sys, json
d = json.load(sys.stdin)
p = json.loads(d.get('payload','{}').strip('\"').replace('\\\\\"','\"'))
assert p['has_premium'] == False
assert p['multiplier'] == 1.0
print('OK: No premium, multiplier=1.0')
"

# Активировать Premium на 30 дней:
curl -sf -X POST "http://localhost:7350/v2/rpc/premium%2Factivate" \
  -H "Authorization: Bearer $AUTH" -d '{"days": 30}' | python3 -c "
import sys, json
d = json.load(sys.stdin)
p = json.loads(d.get('payload','{}').strip('\"').replace('\\\\\"','\"'))
assert p['success'] == True
assert p['days'] == 30
print('OK: Premium activated for', p['days'], 'days')
"

# Статус с Premium:
curl -sf -X POST "http://localhost:7350/v2/rpc/premium%2Fstatus" \
  -H "Authorization: Bearer $AUTH" -d '{}' | python3 -c "
import sys, json
d = json.load(sys.stdin)
p = json.loads(d.get('payload','{}').strip('\"').replace('\\\\\"','\"'))
assert p['has_premium'] == True
assert p['multiplier'] == 2.0
print('OK: Premium active, multiplier=2.0')
"

# award_coins с Premium (100 * 2 = 200):
curl -sf -X POST "http://localhost:7350/v2/rpc/economy%2Faward_coins" \
  -H "Authorization: Bearer $AUTH" \
  -d '{"amount": 100, "reason": "test"}' | python3 -c "
import sys, json
d = json.load(sys.stdin)
p = json.loads(d.get('payload','{}').strip('\"').replace('\\\\\"','\"'))
assert p['final_amount'] == 200, f'Expected 200, got {p[\"final_amount\"]}'
print('OK: Premium x2 multiplier works:', p['base_amount'], '→', p['final_amount'])
"

docker compose down
```

---

## ЗАДАЧА 4 — Финансовая аналитика для питч-дека

Добавь в `backend/apps/monetization/views.py`:

```python
class RevenueAnalyticsView(View):
    """
    GET /api/v1/shop/analytics/
    Финансовая аналитика для питч-дека — сколько заработали, прогноз.
    """

    def get(self, request):
        from django.db.models import Sum, Count
        from django.utils import timezone
        from datetime import timedelta

        now = timezone.now()
        last_30d = now - timedelta(days=30)
        last_7d = now - timedelta(days=7)

        paid_orders = Order.objects.filter(status=Order.Status.PAID)

        # Выручка
        total_revenue = paid_orders.aggregate(
            total=Sum('amount_rub'))['total'] or 0
        revenue_30d = paid_orders.filter(
            paid_at__gte=last_30d).aggregate(
            total=Sum('amount_rub'))['total'] or 0
        revenue_7d = paid_orders.filter(
            paid_at__gte=last_7d).aggregate(
            total=Sum('amount_rub'))['total'] or 0

        # Конверсия
        from apps.platform.models import UserProfile
        total_users = UserProfile.objects.count()
        paying_users = paid_orders.values('nakama_user_id').distinct().count()
        conversion = round(paying_users / max(total_users, 1) * 100, 2)

        # ARPU
        arpu = round(float(total_revenue) / max(paying_users, 1), 2)

        # Прогноз при MAU = 50K (цель для продажи)
        mau_target = 50000
        projected_paying = int(mau_target * (conversion / 100))
        projected_revenue_month = round(projected_paying * arpu, 0)

        # Пакеты — что покупают
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
                'note': f'При конверсии {conversion}% и ARPU {arpu}₽'
            },
            'popular_packages': popular_packages,
            'subscriptions_active': Subscription.objects.filter(
                status=Subscription.Status.ACTIVE).count(),
        })
```

### Приёмочные тесты задачи 4:
```bash
cd backend && python manage.py runserver &
sleep 3

curl -sf http://localhost:8000/api/v1/shop/analytics/ | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert 'revenue' in d
assert 'forecast_50k_mau' in d
assert 'conversion_pct' in d['users']
print('OK: Analytics endpoint works')
print('  Total revenue:', d['revenue']['total_rub'], 'rub')
print('  Conversion:', d['users']['conversion_pct'], '%')
print('  Forecast at 50K MAU:', d['forecast_50k_mau']['projected_monthly_revenue_rub'], 'rub/mo')
"

kill %1
```

---

## ✅ ФИНАЛЬНАЯ ПРИЁМКА НЕДЕЛИ 4

```bash
docker compose up -d && sleep 20
cd backend && python manage.py migrate
python manage.py seed_monetization
python manage.py runserver &
sleep 3

AUTH=$(curl -sf -X POST "http://localhost:7350/v2/account/authenticate/device?create=true" \
  -u "playru-server-key:" -H "Content-Type: application/json" \
  -d '{"id":"final-w4-'$$'"}' | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

echo "--- Django Shop API ---"
for url in \
  "http://localhost:8000/api/v1/shop/packages/" \
  "http://localhost:8000/api/v1/shop/analytics/" \
  "http://localhost:8000/api/v1/public/metrics/"; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$url")
  [ "$STATUS" = "200" ] && echo "OK: $url" || echo "FAIL: $url ($STATUS)"
done

echo "--- Nakama Premium RPCs ---"
for rpc in "premium%2Fstatus" "premium%2Factivate" "economy%2Faward_coins"; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "http://localhost:7350/v2/rpc/$rpc" \
    -H "Authorization: Bearer $AUTH" -d '{}')
  [ "$STATUS" != "404" ] && echo "OK: $rpc" || echo "FAIL: $rpc"
done

echo "--- Пакеты PlayCoin ---"
curl -sf http://localhost:8000/api/v1/shop/packages/ | python3 -c "
import sys, json
d = json.load(sys.stdin)
pkgs = d['packages']
assert len(pkgs) >= 4
prices = [float(p['price_rub']) for p in pkgs]
assert 49.0 in prices and 99.0 in prices and 299.0 in prices
print(f'OK: {len(pkgs)} packages at', prices)
"

echo "--- Все тесты ---"
pytest tests/ -v --tb=short
FAILS=$(pytest tests/ 2>&1 | grep -c "FAILED" || true)

kill %1 2>/dev/null
docker compose down

echo ""
[ "$FAILS" -eq 0 ] && echo "================================================" || true
[ "$FAILS" -eq 0 ] && echo "  НЕДЕЛЯ 4 ВЫПОЛНЕНА — МОНЕТИЗАЦИЯ ГОТОВА" || echo "FAIL: $FAILS tests"
[ "$FAILS" -eq 0 ] && echo "  Пакеты: 49₽ / 99₽ / 299₽ / 799₽" || true
[ "$FAILS" -eq 0 ] && echo "  Premium: x2 монеты, 150 daily reward" || true
[ "$FAILS" -eq 0 ] && echo "  ЮKassa: заглушка, готова к подключению" || true
[ "$FAILS" -eq 0 ] && echo "  Аналитика: прогноз выручки для питч-дека" || true
[ "$FAILS" -eq 0 ] && echo "================================================" || true
```

> **Агент останавливается здесь и ждёт команды.**
