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
