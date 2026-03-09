from datetime import timedelta

from django.contrib.admin.views.decorators import staff_member_required
from django.db.models import Count
from django.shortcuts import redirect, render
from django.utils import timezone

try:
    from apps.developer.models import DeveloperProfile, GameSubmission
except ImportError:
    DeveloperProfile = None
    GameSubmission = None

try:
    from apps.games.models import Game
except ImportError:
    Game = None


def _publish_submission(submission):
    """Создать/обновить Game в каталоге при одобрении GameSubmission."""
    if Game is None:
        submission.status = 'published'
        submission.save(update_fields=['status'])
        return

    defaults = {
        'title': submission.title,
        'description': submission.description,
        'short_description': submission.description[:300],
        'genre': submission.genre,
        'min_age': submission.min_age,
        'nakama_match_label': submission.nakama_module_name,
        'lua_module_name': submission.nakama_module_name,
        'entry_scene': getattr(submission, 'entry_scene', '') or '',
        'status': Game.Status.PUBLISHED,
    }

    # Копируем PCK из submission в Game
    if submission.pck_file:
        import hashlib
        from django.core.files.base import ContentFile

        submission.pck_file.seek(0)
        content = submission.pck_file.read()
        pck_hash = hashlib.sha256(content).hexdigest()

        defaults['pck_hash'] = pck_hash
        defaults['pck_size'] = len(content)
        defaults['pck_version'] = timezone.now().strftime('%Y%m%d%H%M')

        game_obj, _ = Game.objects.update_or_create(
            slug=submission.slug, defaults=defaults,
        )
        game_obj.pck_file.save(
            f'{submission.slug}.pck', ContentFile(content), save=True,
        )
    else:
        game_obj, _ = Game.objects.update_or_create(
            slug=submission.slug, defaults=defaults,
        )

    submission.game = game_obj
    submission.status = 'published'
    submission.save(update_fields=['status', 'game'])


@staff_member_required
def moderation_queue(request):
    if GameSubmission is None:
        return render(request, 'admin/moderation/queue.html', {
            'title': 'Очередь модерации',
            'submissions': [],
            'pending_count': 0,
        })

    pending = GameSubmission.objects.filter(
        status='pending'
    ).select_related('developer', 'developer__user').order_by('submitted_at')

    if request.method == 'POST':
        submission_id = request.POST.get('submission_id')
        action = request.POST.get('action')
        try:
            submission = GameSubmission.objects.get(pk=submission_id)
        except GameSubmission.DoesNotExist:
            return redirect('moderation-queue')

        if action == 'approve':
            _publish_submission(submission)
        elif action == 'reject':
            reason = request.POST.get('rejection_reason', '')
            submission.status = 'rejected'
            submission.rejection_reason = reason
            submission.save(update_fields=['status', 'rejection_reason'])

        return redirect('moderation-queue')

    return render(request, 'admin/moderation/queue.html', {
        'title': 'Очередь модерации',
        'submissions': pending,
        'pending_count': pending.count(),
    })


@staff_member_required
def moderation_stats(request):
    context = {
        'title': 'Статистика модерации',
        'total_developers': 0,
        'status_counts': {},
        'today_submissions': 0,
        'week_submissions': 0,
        'top_developers': [],
    }

    if DeveloperProfile is not None:
        context['total_developers'] = DeveloperProfile.objects.count()

    if GameSubmission is not None:
        now = timezone.now()
        today_start = now.replace(hour=0, minute=0, second=0, microsecond=0)
        week_ago = now - timedelta(days=7)

        status_qs = GameSubmission.objects.values('status').annotate(
            count=Count('id')
        )
        context['status_counts'] = {
            row['status']: row['count'] for row in status_qs
        }
        context['total_games'] = sum(context['status_counts'].values())

        context['today_submissions'] = GameSubmission.objects.filter(
            submitted_at__gte=today_start
        ).count()

        context['week_submissions'] = GameSubmission.objects.filter(
            submitted_at__gte=week_ago
        ).count()

        context['top_developers'] = list(
            DeveloperProfile.objects.annotate(
                game_count=Count('games')
            ).order_by('-game_count')[:5]
        )

    return render(request, 'admin/moderation/stats.html', context)
