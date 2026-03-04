from django.db import models
import uuid


class UserProfile(models.Model):
    """
    Профиль пользователя PlayRU.
    nakama_user_id — ID из Nakama, является основным идентификатором.
    """
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    nakama_user_id = models.CharField(max_length=100, unique=True, db_index=True)

    display_name = models.CharField(max_length=80, verbose_name='Имя игрока')
    avatar_url = models.URLField(blank=True, verbose_name='URL аватара')

    # Авторизация
    class AuthProvider(models.TextChoices):
        VK = 'vk', 'VK'
        YANDEX = 'yandex', 'Яндекс'
        GUEST = 'guest', 'Гость'

    auth_provider = models.CharField(
        max_length=20,
        choices=AuthProvider.choices,
        default=AuthProvider.GUEST
    )
    external_id = models.CharField(max_length=100, blank=True)

    # Статистика
    total_play_time_minutes = models.PositiveIntegerField(default=0)
    games_played = models.PositiveIntegerField(default=0)
    games_completed = models.PositiveIntegerField(default=0)

    # Мета
    is_banned = models.BooleanField(default=False)
    ban_reason = models.TextField(blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    last_seen = models.DateTimeField(auto_now=True)

    class Meta:
        verbose_name = 'Профиль'
        verbose_name_plural = 'Профили'
        ordering = ['-last_seen']

    def __str__(self):
        return f'{self.display_name} ({self.auth_provider})'


class GameSession(models.Model):
    """Запись об игровой сессии — для аналитики и продажи платформы."""

    session_id = models.UUIDField(default=uuid.uuid4, unique=True, db_index=True)
    nakama_user_id = models.CharField(max_length=100, db_index=True)
    game = models.ForeignKey('games.Game', on_delete=models.SET_NULL,
                              null=True, related_name='sessions')

    started_at = models.DateTimeField(auto_now_add=True)
    ended_at = models.DateTimeField(null=True, blank=True)
    duration_seconds = models.PositiveIntegerField(default=0)

    score = models.PositiveBigIntegerField(default=0)
    completed = models.BooleanField(default=False)

    # Для продажи: метаданные устройства
    platform = models.CharField(max_length=20, default='android',
                                  choices=[('android', 'Android'), ('ios', 'iOS'), ('web', 'Web')])

    class Meta:
        verbose_name = 'Игровая сессия'
        verbose_name_plural = 'Игровые сессии'
        ordering = ['-started_at']
        indexes = [
            models.Index(fields=['nakama_user_id', 'started_at']),
            models.Index(fields=['game', 'started_at']),
        ]

    def __str__(self):
        return f'Session {self.session_id} ({self.nakama_user_id})'


class PlatformStats(models.Model):
    """Агрегированная статистика за день — для питч-дека Яндексу."""

    date = models.DateField(unique=True, db_index=True)
    dau = models.PositiveIntegerField(default=0, verbose_name='DAU')
    new_users = models.PositiveIntegerField(default=0)
    total_sessions = models.PositiveIntegerField(default=0)
    total_playtime_hours = models.FloatField(default=0.0)
    revenue_rub = models.DecimalField(max_digits=12, decimal_places=2, default=0)

    class Meta:
        verbose_name = 'Статистика платформы'
        verbose_name_plural = 'Статистика платформы'
        ordering = ['-date']

    def __str__(self):
        return f'Stats {self.date}: DAU={self.dau}'
