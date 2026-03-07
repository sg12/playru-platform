from django.db import models


class DeveloperApplication(models.Model):
    STATUS_CHOICES = [
        ('pending', 'На рассмотрении'),
        ('approved', 'Одобрена'),
        ('rejected', 'Отклонена'),
    ]

    name = models.CharField('Имя', max_length=200)
    email = models.EmailField('Email')
    game_description = models.TextField('Описание игры')
    status = models.CharField(
        'Статус', max_length=20, choices=STATUS_CHOICES, default='pending'
    )
    created_at = models.DateTimeField('Дата подачи', auto_now_add=True)

    class Meta:
        verbose_name = 'Заявка разработчика'
        verbose_name_plural = 'Заявки разработчиков'
        ordering = ['-created_at']

    def __str__(self):
        return f'{self.name} — {self.get_status_display()}'
