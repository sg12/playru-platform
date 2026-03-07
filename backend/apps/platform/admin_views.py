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
            submission.status = 'published'
            submission.save(update_fields=['status'])
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
