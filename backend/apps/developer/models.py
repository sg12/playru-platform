from django.conf import settings
from django.db import models


class DeveloperProfile(models.Model):
    user = models.OneToOneField(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name='developer_profile',
    )
    display_name = models.CharField('Отображаемое имя', max_length=100)
    bio = models.TextField('О себе', blank=True)
    total_earnings = models.DecimalField(
        'Общий заработок',
        max_digits=12,
        decimal_places=2,
        default=0,
    )
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        verbose_name = 'Профиль разработчика'
        verbose_name_plural = 'Профили разработчиков'

    def __str__(self):
        return self.display_name


class GameSubmission(models.Model):
    class Status(models.TextChoices):
        DRAFT = 'draft', 'Черновик'
        PENDING = 'pending', 'На модерации'
        APPROVED = 'approved', 'Одобрена'
        REJECTED = 'rejected', 'Отклонена'
        PUBLISHED = 'published', 'Опубликована'

    developer = models.ForeignKey(
        DeveloperProfile,
        on_delete=models.CASCADE,
        related_name='games',
    )
    title = models.CharField('Название', max_length=200)
    slug = models.SlugField('Слаг', unique=True)
    description = models.TextField('Описание')
    genre = models.CharField('Жанр', max_length=50)
    min_age = models.IntegerField('Минимальный возраст', default=6)
    status = models.CharField(
        'Статус',
        max_length=20,
        choices=Status.choices,
        default=Status.DRAFT,
    )
    rejection_reason = models.TextField('Причина отклонения', blank=True)
    godot_repo_url = models.URLField('Godot репозиторий', blank=True)
    nakama_module_name = models.CharField('Nakama модуль', max_length=200, blank=True)
    submitted_at = models.DateTimeField('Дата отправки', null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        verbose_name = 'Заявка на игру'
        verbose_name_plural = 'Заявки на игры'
        ordering = ['-created_at']

    def __str__(self):
        return self.title
