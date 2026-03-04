from django.core.management.base import BaseCommand
from apps.games.models import Game


GAMES = [
    {
        'slug': 'parkour',
        'title': 'Паркур',
        'description': 'Пробегись по городским крышам! Прыгай по платформам, '
                       'собирай монеты и устанавливай рекорды скорости. '
                       'Простое управление, затягивающий геймплей.',
        'short_description': 'Паркур по крышам с рекордами',
        'genre': 'runner',
        'min_age': 6,
        'tags': ['паркур', 'бег', 'рекорды', '3D'],
        'status': 'published',
        'is_featured': True,
    },
    {
        'slug': 'arena_shooter',
        'title': 'Арена',
        'description': 'Сражайся против других игроков в 3D арене! '
                       'Используй тактику, следи за здоровьем, набирай очки убийств. '
                       'Лидеры получают больше PlayCoin.',
        'short_description': 'Динамичный шутер на арене',
        'genre': 'shooter',
        'min_age': 10,
        'tags': ['арена', 'шутер', 'PvP', '3D'],
        'status': 'published',
        'is_featured': True,
    },
    {
        'slug': 'clicker',
        'title': 'Кликер',
        'description': 'Классический кликер с прокачкой! Нажимай, покупай улучшения, '
                       'автоматизируй производство. Четыре уровня апгрейдов ждут тебя.',
        'short_description': 'Тапай, собирай очки, покупай улучшения',
        'genre': 'idle',
        'min_age': 6,
        'tags': ['кликер', 'idle', 'прокачка'],
        'status': 'published',
        'lua_module_name': 'clicker',
    },
    {
        'slug': 'racing',
        'title': 'Гонки',
        'description': '3 круга по трассе на настоящей физике! Управляй болидом, '
                       'проезжай через чекпоинты, бей рекорд круга. '
                       'Чем быстрее — тем больше PlayCoin.',
        'short_description': 'Гонки с физикой и рекордами',
        'genre': 'racing',
        'min_age': 8,
        'tags': ['гонки', '3D', 'физика', 'рекорд'],
        'status': 'published',
        'lua_module_name': 'racing',
    },
    {
        'slug': 'tower_defense',
        'title': 'Защита башни',
        'description': 'Строй башни, останавливай волны врагов! 10 волн всё сложнее. '
                       'Зарабатывай монеты за убийства и трать на новые башни. '
                       'Не дай врагам добраться до базы!',
        'short_description': 'Стратегическая защита башнями',
        'genre': 'strategy',
        'min_age': 8,
        'tags': ['TD', 'стратегия', 'башни', 'волны'],
        'status': 'published',
        'is_featured': True,
        'lua_module_name': 'tower_defense',
    },
    {
        'slug': 'island_survival',
        'title': 'Остров выживания',
        'description': 'Выживи на необитаемом острове! Собирай ресурсы, крафти предметы, '
                       'следи за голодом. Построй плот чтобы спастись. '
                       'Чем дольше продержишься — тем больше наград.',
        'short_description': 'Выживание на необитаемом острове',
        'genre': 'survival',
        'min_age': 10,
        'tags': ['выживание', 'крафт', 'остров', 'ресурсы'],
        'status': 'published',
        'lua_module_name': 'island_survival',
    },
    {
        'slug': 'mining_simulator',
        'title': 'Шахтёр',
        'description': 'Копай руду, продавай и покупай инструменты! '
                       'От простой кирки до лазера — 5 уровней прокачки. '
                       'Копай глубже — зарабатывай больше.',
        'short_description': 'Копай руду, прокачивай инструменты',
        'genre': 'idle',
        'min_age': 6,
        'tags': ['шахтёр', 'idle', 'прокачка', 'ресурсы'],
        'status': 'published',
    },
    {
        'slug': 'quiz_battle',
        'title': 'Викторина',
        'description': 'Проверь знания по IT, математике и науке! '
                       'Отвечай быстро — бонус за скорость. '
                       'Стань чемпионом таблицы лидеров.',
        'short_description': 'Викторина по IT и науке',
        'genre': 'quiz',
        'min_age': 10,
        'tags': ['викторина', 'знания', 'IT', 'образование'],
        'status': 'published',
    },
    {
        'slug': 'snake',
        'title': 'Змейка',
        'description': 'Классическая змейка! Собирай яблоки, расти, '
                       'не врезайся в стены и себя. '
                       'Управление: стрелки или свайп на телефоне.',
        'short_description': 'Классическая аркадная змейка',
        'genre': 'arcade',
        'min_age': 6,
        'tags': ['змейка', 'классика', 'аркада'],
        'status': 'published',
    },
    {
        'slug': 'math_battle',
        'title': 'Математический бой',
        'description': 'Соревнуйся с AI в решении примеров! '
                       '10 раундов, 3 уровня сложности — от сложения до деления. '
                       'Побеждай быстрее AI и получай больше PlayCoin.',
        'short_description': 'Соревнуйся с AI в математике',
        'genre': 'educational',
        'min_age': 8,
        'tags': ['математика', 'образование', 'AI', 'викторина'],
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
