# AGENT 1 — playru-platform — НЕДЕЛЯ 5
## Рейтинги игр, отзывы, админ-панель, локализация API

> Продолжаем в playru-platform. 28/28 тестов зелёные.
> Цель недели: платформа выглядит как продукт, а не прототип —
> рейтинги, отзывы, русский контент, модерация.
> После каждой задачи — приёмочные тесты. Стоп после ФИНАЛЬНОЙ ПРИЁМКИ.

---

## ЗАДАЧА 1 — Рейтинги и отзывы игр

Создай `backend/apps/games/models_ratings.py` (добавь в `models.py`):

```python
class GameRating(models.Model):
    """Оценка игры от пользователя."""

    class Stars(models.IntegerChoices):
        ONE   = 1, '⭐'
        TWO   = 2, '⭐⭐'
        THREE = 3, '⭐⭐⭐'
        FOUR  = 4, '⭐⭐⭐⭐'
        FIVE  = 5, '⭐⭐⭐⭐⭐'

    game = models.ForeignKey('Game', on_delete=models.CASCADE,
                               related_name='ratings')
    nakama_user_id = models.CharField(max_length=100, db_index=True)
    stars = models.PositiveSmallIntegerField(choices=Stars.choices)
    review = models.TextField(max_length=500, blank=True)
    is_approved = models.BooleanField(default=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        unique_together = [('game', 'nakama_user_id')]
        verbose_name = 'Оценка игры'
        indexes = [models.Index(fields=['game', 'is_approved'])]

    def __str__(self):
        return f'{self.game.title} — {self.stars}★ от {self.nakama_user_id[:8]}'
```

Добавь сигнал для пересчёта среднего рейтинга в `Game`:
```python
from django.db.models import Avg
from django.db.models.signals import post_save
from django.dispatch import receiver

# В модель Game добавь поля:
avg_rating = models.DecimalField(max_digits=3, decimal_places=2, default=0.00)
ratings_count = models.PositiveIntegerField(default=0)

@receiver(post_save, sender='games.GameRating')
def update_game_rating(sender, instance, **kwargs):
    game = instance.game
    result = game.ratings.filter(is_approved=True).aggregate(
        avg=Avg('stars'), count=models.Count('id'))
    game.avg_rating = round(result['avg'] or 0, 2)
    game.ratings_count = result['count'] or 0
    game.save(update_fields=['avg_rating', 'ratings_count'])
```

**Endpoints** в `backend/apps/games/views.py`:

```python
class GameRateView(View):
    """
    POST /api/v1/games/<slug>/rate/
    Поставить оценку игре.
    Body: {nakama_user_id, stars (1-5), review?}
    """
    def post(self, request, slug):
        import json
        from .models import Game, GameRating
        try:
            data = json.loads(request.body)
        except Exception:
            return JsonResponse({'error': 'Invalid JSON'}, status=400)

        try:
            game = Game.objects.get(slug=slug)
        except Game.DoesNotExist:
            return JsonResponse({'error': 'Game not found'}, status=404)

        user_id = data.get('nakama_user_id', '')
        stars = int(data.get('stars', 0))
        if not user_id or stars not in range(1, 6):
            return JsonResponse({'error': 'nakama_user_id and stars 1-5 required'}, status=400)

        rating, created = GameRating.objects.update_or_create(
            game=game, nakama_user_id=user_id,
            defaults={'stars': stars, 'review': data.get('review', '')[:500]}
        )
        action = 'created' if created else 'updated'
        return JsonResponse({
            'success': True,
            'action': action,
            'game_avg_rating': float(game.avg_rating),
            'game_ratings_count': game.ratings_count,
        })


class GameReviewsView(View):
    """GET /api/v1/games/<slug>/reviews/ — список отзывов."""
    def get(self, request, slug):
        from .models import Game, GameRating
        try:
            game = Game.objects.get(slug=slug)
        except Game.DoesNotExist:
            return JsonResponse({'error': 'Not found'}, status=404)

        reviews = GameRating.objects.filter(
            game=game, is_approved=True, review__gt=''
        ).order_by('-created_at')[:20]

        return JsonResponse({
            'game': slug,
            'avg_rating': float(game.avg_rating),
            'ratings_count': game.ratings_count,
            'reviews': [
                {
                    'stars': r.stars,
                    'review': r.review,
                    'user_short': r.nakama_user_id[:8] + '...',
                    'date': r.created_at.strftime('%d.%m.%Y'),
                }
                for r in reviews
            ]
        })
```

Добавь в `backend/config/urls.py`:
```python
from apps.games.views import GameRateView, GameReviewsView
urlpatterns += [
    path('api/v1/games/<slug:slug>/rate/', GameRateView.as_view()),
    path('api/v1/games/<slug:slug>/reviews/', GameReviewsView.as_view()),
]
```

Добавь в admin с list_display, list_filter по stars и is_approved, search_fields.

### Приёмочные тесты задачи 1:
```bash
cd backend
python manage.py makemigrations games
python manage.py migrate && echo "OK: migrations"

python manage.py runserver &
sleep 3

# Поставить оценку:
curl -sf -X POST http://localhost:8000/api/v1/games/parkour/rate/ \
  -H "Content-Type: application/json" \
  -d '{"nakama_user_id":"user-abc","stars":5,"review":"Отличная игра!"}' \
  | python3 -c "
import sys, json; d=json.load(sys.stdin)
assert d['success']==True
print('OK: Rating created, avg=', d['game_avg_rating'])
"

# Обновить оценку (должен быть update, не duplicate):
curl -sf -X POST http://localhost:8000/api/v1/games/parkour/rate/ \
  -H "Content-Type: application/json" \
  -d '{"nakama_user_id":"user-abc","stars":4}' \
  | python3 -c "
import sys,json; d=json.load(sys.stdin)
assert d['action']=='updated'
print('OK: Rating updated, avg=', d['game_avg_rating'])
"

# Список отзывов:
curl -sf http://localhost:8000/api/v1/games/parkour/reviews/ | python3 -c "
import sys,json; d=json.load(sys.stdin)
assert 'reviews' in d
assert d['ratings_count'] >= 1
print('OK: Reviews:', d['ratings_count'], 'ratings, avg:', d['avg_rating'])
"

pytest tests/ -v -k "rating or review" --tb=short 2>/dev/null || true
kill %1
```

---

## ЗАДАЧА 2 — Полный Django Admin для питч-дека

Создай `backend/apps/platform/admin_dashboard.py`:

```python
"""
Кастомный Django Admin с дашбордом — для демонстрации инвесторам.
URL: /admin/  — видит ключевые метрики платформы.
"""
from django.contrib import admin
from django.contrib.admin import AdminSite
from django.urls import path
from django.http import JsonResponse
from django.template.response import TemplateResponse
from django.utils import timezone
from datetime import timedelta


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
        """API для дашборда — вызывается из inline JS."""
        from apps.platform.models import UserProfile, PlatformStats
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
            t=sum('amount_rub'))['t'] or 0

        return JsonResponse({
            'dau': dau, 'mau': mau, 'total_users': total,
            'games': Game.objects.filter(status='published').count(),
            'revenue_rub': float(revenue),
            'retention': round(dau / max(total, 1) * 100, 1),
        })


playru_admin = PlayRUAdminSite(name='playru_admin')
```

Обнови admin регистрацию всех моделей — добавь `list_display`, `list_filter`, `search_fields`, `date_hierarchy` для:

**`backend/apps/games/admin.py`**:
```python
from django.contrib import admin
from .models import Game, GameRating

@admin.register(Game)
class GameAdmin(admin.ModelAdmin):
    list_display  = ['title', 'slug', 'status', 'play_count',
                     'avg_rating', 'ratings_count', 'created_at']
    list_filter   = ['status', 'genre']
    search_fields = ['title', 'slug', 'description']
    readonly_fields = ['play_count', 'avg_rating', 'ratings_count']
    prepopulated_fields = {'slug': ('title',)}
    ordering = ['-play_count']


@admin.register(GameRating)
class GameRatingAdmin(admin.ModelAdmin):
    list_display  = ['game', 'stars', 'review_short', 'is_approved', 'created_at']
    list_filter   = ['stars', 'is_approved', 'game']
    search_fields = ['review', 'nakama_user_id']
    date_hierarchy = 'created_at'
    actions = ['approve_selected', 'reject_selected']

    def review_short(self, obj):
        return obj.review[:60] + '...' if len(obj.review) > 60 else obj.review
    review_short.short_description = 'Отзыв'

    def approve_selected(self, request, queryset):
        queryset.update(is_approved=True)
    approve_selected.short_description = 'Одобрить выбранные'

    def reject_selected(self, request, queryset):
        queryset.update(is_approved=False)
    reject_selected.short_description = 'Отклонить выбранные'
```

**`backend/apps/monetization/admin.py`**:
```python
from django.contrib import admin
from .models import PlayCoinPackage, Order, Subscription


@admin.register(PlayCoinPackage)
class PackageAdmin(admin.ModelAdmin):
    list_display  = ['name', 'coins', 'bonus_coins', 'total_coins',
                     'price_rub', 'is_popular', 'is_active']
    list_filter   = ['is_active', 'is_popular']
    ordering      = ['sort_order']


@admin.register(Order)
class OrderAdmin(admin.ModelAdmin):
    list_display  = ['id_short', 'order_type', 'status', 'amount_rub',
                     'coins_amount', 'created_at', 'paid_at']
    list_filter   = ['status', 'order_type', 'payment_provider']
    search_fields = ['nakama_user_id', 'payment_id']
    date_hierarchy = 'created_at'
    readonly_fields = ['id', 'created_at', 'paid_at']

    def id_short(self, obj):
        return str(obj.id)[:8] + '...'
    id_short.short_description = 'ID'


@admin.register(Subscription)
class SubscriptionAdmin(admin.ModelAdmin):
    list_display = ['id', 'nakama_user_id', 'status', 'expires_at', 'auto_renew']
    list_filter  = ['status', 'auto_renew']
    date_hierarchy = 'started_at'
```

### Приёмочные тесты задачи 2:
```bash
cd backend
python manage.py check && echo "OK: Django check"

python manage.py runserver &
sleep 3

# Admin доступен:
STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/admin/)
[ "$STATUS" = "302" ] && echo "OK: Admin redirects to login (302)" || echo "FAIL: Admin status $STATUS"

# Создать superuser:
echo "from django.contrib.auth import get_user_model; \
U=get_user_model(); U.objects.filter(username='admin').delete(); \
U.objects.create_superuser('admin','admin@playru.ru','admin123')" \
  | python manage.py shell -c "$(cat)"

# Логин и проверка admin:
COOKIE=$(curl -sc /tmp/cookies.txt -X POST http://localhost:8000/admin/login/ \
  --data "username=admin&password=admin123&csrfmiddlewaretoken=$(curl -s http://localhost:8000/admin/login/ | grep csrfmiddlewaretoken | head -1 | sed 's/.*value=\"\([^\"]*\)\".*/\1/')" \
  -b /tmp/cookies.txt -o /dev/null -w "%{http_code}")
echo "OK: Admin login: $COOKIE"

pytest tests/ -v --tb=short 2>/dev/null || true
kill %1
```

---

## ЗАДАЧА 3 — Seed 10 игр в Django с описаниями на русском

Обнови `backend/apps/games/management/commands/seed_games.py`:

```python
from django.core.management.base import BaseCommand
from apps.games.models import Game


GAMES = [
    {
        'slug': 'parkour',
        'title': 'Паркур',
        'description': 'Пробегись по городским крышам! Прыгай по платформам, '
                       'собирай монеты и устанавливай рекорды скорости. '
                       'Простое управление, затягивающий геймплей.',
        'genre': 'runner',
        'min_age': 6,
        'tags': 'паркур,бег,рекорды,3D',
        'status': 'published',
    },
    {
        'slug': 'arena_shooter',
        'title': 'Арена',
        'description': 'Сражайся против других игроков в 3D арене! '
                       'Используй тактику, следи за здоровьем, набирай очки убийств. '
                       'Лидеры получают больше PlayCoin.',
        'genre': 'shooter',
        'min_age': 10,
        'tags': 'арена,шутер,PvP,3D',
        'status': 'published',
    },
    {
        'slug': 'clicker',
        'title': 'Кликер',
        'description': 'Классический кликер с прокачкой! Нажимай, покупай улучшения, '
                       'автоматизируй производство. Четыре уровня апгрейдов ждут тебя.',
        'genre': 'idle',
        'min_age': 6,
        'tags': 'кликер,idle,прокачка',
        'status': 'published',
    },
    {
        'slug': 'racing',
        'title': 'Гонки',
        'description': '3 круга по трассе на настоящей физике! Управляй болидом, '
                       'проезжай через чекпоинты, бей рекорд круга. '
                       'Чем быстрее — тем больше PlayCoin.',
        'genre': 'racing',
        'min_age': 8,
        'tags': 'гонки,3D,физика,рекорд',
        'status': 'published',
    },
    {
        'slug': 'tower_defense',
        'title': 'Защита башни',
        'description': 'Строй башни, останавливай волны врагов! 10 волн всё сложнее. '
                       'Зарабатывай монеты за убийства и трать на новые башни. '
                       'Не дай врагам добраться до базы!',
        'genre': 'strategy',
        'min_age': 8,
        'tags': 'TD,стратегия,башни,волны',
        'status': 'published',
    },
    {
        'slug': 'island_survival',
        'title': 'Остров выживания',
        'description': 'Выживи на необитаемом острове! Собирай ресурсы, крафти предметы, '
                       'следи за голодом. Построй плот чтобы спастись. '
                       'Чем дольше продержишься — тем больше наград.',
        'genre': 'survival',
        'min_age': 10,
        'tags': 'выживание,крафт,остров,ресурсы',
        'status': 'published',
    },
    {
        'slug': 'mining_simulator',
        'title': 'Шахтёр',
        'description': 'Копай руду, продавай и покупай инструменты! '
                       'От простой кирки до лазера — 5 уровней прокачки. '
                       'Копай глубже — зарабатывай больше.',
        'genre': 'idle',
        'min_age': 6,
        'tags': 'шахтёр,idle,прокачка,ресурсы',
        'status': 'published',
    },
    {
        'slug': 'quiz_battle',
        'title': 'Викторина',
        'description': 'Проверь знания по IT, математике и науке! '
                       'Отвечай быстро — бонус за скорость. '
                       'Стань чемпионом таблицы лидеров.',
        'genre': 'quiz',
        'min_age': 10,
        'tags': 'викторина,знания,IT,образование',
        'status': 'published',
    },
    {
        'slug': 'snake',
        'title': 'Змейка',
        'description': 'Классическая змейка! Собирай яблоки, расти, '
                       'не врезайся в стены и себя. '
                       'Управление: стрелки или свайп на телефоне.',
        'genre': 'arcade',
        'min_age': 6,
        'tags': 'змейка,классика,аркада',
        'status': 'published',
    },
    {
        'slug': 'math_battle',
        'title': 'Математический бой',
        'description': 'Соревнуйся с AI в решении примеров! '
                       '10 раундов, 3 уровня сложности — от сложения до деления. '
                       'Побеждай быстрее AI и получай больше PlayCoin.',
        'genre': 'educational',
        'min_age': 8,
        'tags': 'математика,образование,AI,викторина',
        'status': 'published',
    },
]


class Command(BaseCommand):
    help = 'Seed 10 игр с описаниями на русском'

    def handle(self, *args, **options):
        for data in GAMES:
            obj, created = Game.objects.update_or_create(
                slug=data['slug'], defaults=data)
            self.stdout.write('  %s [%s] — %s' % (
                obj.title, obj.genre,
                'создана' if created else 'обновлена'))
        self.stdout.write(self.style.SUCCESS(
            '\nОК: %d игр в базе' % Game.objects.count()))
```

Проверь что модель `Game` имеет поля `genre`, `min_age`, `tags`, `description` — добавь если нет:
```python
genre    = models.CharField(max_length=30, default='arcade')
min_age  = models.PositiveSmallIntegerField(default=6)
tags     = models.CharField(max_length=200, blank=True)
```

### Приёмочные тесты задачи 3:
```bash
cd backend
python manage.py makemigrations games --name="add_game_meta" 2>/dev/null || true
python manage.py migrate
python manage.py seed_games && echo "OK: games seeded"

python manage.py runserver &
sleep 3

curl -sf http://localhost:8000/api/v1/games/ | python3 -c "
import sys, json
d = json.load(sys.stdin)
count = d.get('count', len(d.get('results', d.get('games', []))))
print(f'OK: {count} games in catalog')

games = d.get('results', d.get('games', []))
for g in games[:3]:
    print(f'  {g[\"title\"]}: {g.get(\"description\",\"\")[:40]}...')
"

kill %1
```

---

## ЗАДАЧА 4 — Snapshot API для питч-дека (одним запросом)

Создай `/api/v1/public/pitch/` — всё что нужно для демонстрации инвесторам:

```python
class PitchDeckSnapshotView(View):
    """
    GET /api/v1/public/pitch/
    Один endpoint со всеми метриками для питч-дека.
    Кэшируется на 5 минут.
    """

    def get(self, request):
        from django.core.cache import cache
        from django.utils import timezone
        from datetime import timedelta
        from apps.games.models import Game
        from apps.platform.models import UserProfile
        from apps.monetization.models import Order, PlayCoinPackage

        CACHE_KEY = 'pitch_deck_snapshot'
        cached = cache.get(CACHE_KEY)
        if cached:
            return JsonResponse(cached)

        now = timezone.now()

        # Пользователи
        total = UserProfile.objects.count()
        dau   = UserProfile.objects.filter(last_seen__gte=now-timedelta(hours=24)).count()
        mau   = UserProfile.objects.filter(last_seen__gte=now-timedelta(days=30)).count()

        # Игры
        games = Game.objects.filter(status='published').order_by('-avg_rating')
        top_games = [
            {'title': g.title, 'rating': float(g.avg_rating),
             'plays': g.play_count, 'genre': g.genre}
            for g in games[:5]
        ]

        # Монетизация
        paid = Order.objects.filter(status='paid')
        revenue = float(sum(o.amount_rub for o in paid))
        paying  = paid.values('nakama_user_id').distinct().count()

        # Пакеты
        packages = [
            {'name': p.name, 'price': str(p.price_rub), 'coins': p.total_coins}
            for p in PlayCoinPackage.objects.filter(is_active=True)
        ]

        data = {
            'project': 'PlayRU',
            'tagline': 'Российская игровая платформа для школьников',
            'snapshot_time': now.isoformat(),
            'traction': {
                'total_users': total,
                'dau': dau,
                'mau': mau,
                'dau_mau_ratio': round(dau/max(mau,1)*100, 1),
                'paying_users': paying,
                'conversion_pct': round(paying/max(total,1)*100, 2),
            },
            'product': {
                'games_count': games.count(),
                'top_games': top_games,
                'platforms': ['Android', 'Web (в разработке)'],
                'min_android_sdk': 24,
            },
            'monetization': {
                'model': 'F2P + PlayCoin + Premium подписка',
                'packages': packages,
                'premium_price_rub': 149,
                'total_revenue_rub': revenue,
                'arpu_rub': round(revenue/max(paying,1), 2),
            },
            'technology': {
                'client': 'Godot 4 (GDScript)',
                'backend': 'Django 4 + Nakama',
                'database': 'PostgreSQL',
                'infra': 'Kubernetes / ArgoCD / Selectel',
                'auth': ['VK OAuth', 'Yandex OAuth', 'Guest'],
            },
            'market': {
                'target': 'Школьники 6-18 лет, Россия',
                'tam_users': 15_000_000,
                'comparable': 'Roblox (заблокирован в РФ с 2022)',
                'est_value_at_50k_mau_rub': 50_000 * 3_000,
            },
        }

        cache.set(CACHE_KEY, data, 300)
        return JsonResponse(data)
```

Добавь в `backend/config/urls.py`:
```python
from apps.platform.views_dashboard import PitchDeckSnapshotView
urlpatterns += [path('api/v1/public/pitch/', PitchDeckSnapshotView.as_view())]
```

### Приёмочные тесты задачи 4:
```bash
cd backend && python manage.py runserver &
sleep 3

curl -sf http://localhost:8000/api/v1/public/pitch/ | python3 -c "
import sys, json
d = json.load(sys.stdin)
required = ['project','traction','product','monetization','technology','market']
for key in required:
    assert key in d, f'Missing: {key}'
    print(f'OK: {key}')

assert d['product']['games_count'] >= 5, 'Need 5+ games'
print('OK: games_count =', d['product']['games_count'])
print('OK: target market:', d['market']['target'])
print('OK: est value at 50K MAU:', d['market']['est_value_at_50k_mau_rub'], 'rub')
"

# Второй запрос — должен вернуть из кэша быстрее:
TIME1=\$(date +%s%N)
curl -sf http://localhost:8000/api/v1/public/pitch/ > /dev/null
TIME2=\$(date +%s%N)
echo "OK: Cache response in \$(( (TIME2-TIME1)/1000000 ))ms"

kill %1
```

---

## ✅ ФИНАЛЬНАЯ ПРИЁМКА НЕДЕЛИ 5

```bash
cd backend
python manage.py migrate
python manage.py seed_games
python manage.py seed_monetization
python manage.py runserver &
sleep 3

echo "--- Endpoints ---"
for url in \
  "http://localhost:8000/api/v1/games/" \
  "http://localhost:8000/api/v1/games/snake/reviews/" \
  "http://localhost:8000/api/v1/shop/packages/" \
  "http://localhost:8000/api/v1/shop/analytics/" \
  "http://localhost:8000/api/v1/public/metrics/" \
  "http://localhost:8000/api/v1/public/pitch/"; do
  STATUS=\$(curl -s -o /dev/null -w "%{http_code}" "\$url")
  [ "\$STATUS" = "200" ] && echo "OK: \$url" || echo "FAIL: \$url (\$STATUS)"
done

echo "--- Рейтинги ---"
for slug in parkour arena_shooter clicker racing tower_defense \
            island_survival mining_simulator quiz_battle snake math_battle; do
  curl -sf -X POST "http://localhost:8000/api/v1/games/\$slug/rate/" \
    -H "Content-Type: application/json" \
    -d "{\"nakama_user_id\":\"seed-user\",\"stars\":5}" > /dev/null \
    && echo "OK: rated \$slug" || echo "FAIL: rating \$slug"
done

echo "--- Pitch deck ---"
curl -sf http://localhost:8000/api/v1/public/pitch/ | python3 -c "
import sys,json; d=json.load(sys.stdin)
print('Games:', d['product']['games_count'])
print('MAU:', d['traction']['mau'])
print('Est value:', d['market']['est_value_at_50k_mau_rub'], 'rub')
"

echo "--- Pytest ---"
pytest tests/ -v --tb=short
kill %1

echo ""
echo "================================================"
echo "  НЕДЕЛЯ 5 ВЫПОЛНЕНА"
echo "  Рейтинги и отзывы для всех 10 игр"
echo "  Admin panel с метриками"
echo "  Pitch deck endpoint для инвесторов"
echo "  10 игр с русскими описаниями в базе"
echo "================================================"
```

> **Агент останавливается здесь и ждёт команды.**
