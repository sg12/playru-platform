try:
    from apps.developer.models import DeveloperProfile, GameSubmission
except ImportError:
    DeveloperProfile = None
    GameSubmission = None


def moderation_alerts(request):
    if not hasattr(request, 'user') or not request.user.is_staff:
        return {}

    context = {}

    if GameSubmission is not None:
        context['pending_games'] = GameSubmission.objects.filter(
            status='pending'
        ).count()

    if DeveloperProfile is not None:
        from datetime import timedelta
        from django.utils import timezone
        week_ago = timezone.now() - timedelta(days=7)
        context['pending_developers'] = DeveloperProfile.objects.filter(
            created_at__gte=week_ago
        ).count()

    return context
