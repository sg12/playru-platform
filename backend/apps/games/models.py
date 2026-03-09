from django.db import models
from django.db.models import Avg, Count
from django.db.models.signals import post_save
from django.dispatch import receiver


class Game(models.Model):
    class Status(models.TextChoices):
        DRAFT = 'draft', 'Черновик'
        PUBLISHED = 'published', 'Опубликована'
        ARCHIVED = 'archived', 'Архив'

    title = models.CharField(max_length=200, verbose_name='Название')
    slug = models.SlugField(unique=True)
    description = models.TextField(verbose_name='Описание', blank=True, default='')
    short_description = models.CharField(max_length=300, verbose_name='Краткое описание',
                                          blank=True, default='')
    thumbnail = models.ImageField(upload_to='games/thumbnails/', null=True, blank=True)

    # Игровые данные
    nakama_match_label = models.CharField(max_length=100, blank=True)
    lua_module_name = models.CharField(max_length=100, blank=True)
    max_players = models.PositiveSmallIntegerField(default=10)
    min_players = models.PositiveSmallIntegerField(default=1)

    # PCK (загружаемые игры)
    pck_file = models.FileField('PCK файл', upload_to='games/pck/', null=True, blank=True)
    pck_hash = models.CharField('SHA-256 хеш', max_length=64, blank=True)
    pck_size = models.PositiveBigIntegerField('Размер PCK (байт)', default=0)
    pck_version = models.CharField('Версия PCK', max_length=20, blank=True)
    entry_scene = models.CharField('Точка входа (сцена)', max_length=200, blank=True)

    # Метрики
    play_count = models.PositiveBigIntegerField(default=0)
    active_players = models.PositiveIntegerField(default=0)
    avg_rating = models.DecimalField(max_digits=3, decimal_places=2, default=0.00)
    ratings_count = models.PositiveIntegerField(default=0)

    # Мета
    status = models.CharField(max_length=20, choices=Status.choices, default=Status.DRAFT)
    is_featured = models.BooleanField(default=False)
    genre = models.CharField(max_length=30, default='arcade')
    min_age = models.PositiveSmallIntegerField(default=6)
    tags = models.JSONField(default=list, blank=True)

    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        verbose_name = 'Игра'
        verbose_name_plural = 'Игры'
        ordering = ['-play_count']

    def __str__(self):
        return self.title


class GameRating(models.Model):
    """Оценка игры от пользователя."""

    class Stars(models.IntegerChoices):
        ONE = 1, '1'
        TWO = 2, '2'
        THREE = 3, '3'
        FOUR = 4, '4'
        FIVE = 5, '5'

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
        return f'{self.game.title} — {self.stars} от {self.nakama_user_id[:8]}'


@receiver(post_save, sender=GameRating)
def update_game_rating(sender, instance, **kwargs):
    game = instance.game
    result = game.ratings.filter(is_approved=True).aggregate(
        avg=Avg('stars'), count=Count('id'))
    game.avg_rating = round(result['avg'] or 0, 2)
    game.ratings_count = result['count'] or 0
    game.save(update_fields=['avg_rating', 'ratings_count'])
