from django.core.management.base import BaseCommand
from apps.monetization.models import PlayCoinPackage


class Command(BaseCommand):
    help = 'Создать стартовые пакеты PlayCoin'

    def handle(self, *args, **options):
        packages = [
            {
                'slug': 'starter',
                'name': 'Стартовый',
                'coins': 100,
                'bonus_coins': 0,
                'price_rub': '49.00',
                'is_popular': False,
                'sort_order': 1,
            },
            {
                'slug': 'popular',
                'name': 'Популярный',
                'coins': 250,
                'bonus_coins': 50,
                'price_rub': '99.00',
                'is_popular': True,
                'sort_order': 2,
            },
            {
                'slug': 'mega',
                'name': 'Мега',
                'coins': 700,
                'bonus_coins': 300,
                'price_rub': '299.00',
                'is_popular': False,
                'sort_order': 3,
            },
            {
                'slug': 'ultra',
                'name': 'Ультра',
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
                f"  {obj.name}: {obj.total_coins} монет за {obj.price_rub}р [{status}]")
        self.stdout.write(self.style.SUCCESS(
            f'\nОК: {PlayCoinPackage.objects.count()} пакетов в базе'))
