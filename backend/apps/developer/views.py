from django.contrib.auth import login, logout, authenticate
from django.contrib.auth.decorators import login_required
from django.contrib.auth.models import User
from django.shortcuts import render, redirect, get_object_or_404
from django.utils import timezone

from .forms import RegisterForm, GameSubmissionForm, ProfileForm
from .models import DeveloperProfile, GameSubmission


def register_view(request):
    if request.user.is_authenticated:
        return redirect('developer:dashboard')
    form = RegisterForm(request.POST or None)
    if request.method == 'POST' and form.is_valid():
        user = User.objects.create_user(
            username=form.cleaned_data['username'],
            email=form.cleaned_data['email'],
            password=form.cleaned_data['password'],
        )
        DeveloperProfile.objects.create(
            user=user,
            display_name=form.cleaned_data['display_name'],
        )
        login(request, user)
        return redirect('developer:dashboard')
    return render(request, 'developer/register.html', {'form': form})


def login_view(request):
    if request.user.is_authenticated:
        return redirect('developer:dashboard')
    error = None
    if request.method == 'POST':
        user = authenticate(
            request,
            username=request.POST.get('username', ''),
            password=request.POST.get('password', ''),
        )
        if user is not None:
            login(request, user)
            return redirect('developer:dashboard')
        error = 'Неверный логин или пароль.'
    return render(request, 'developer/login.html', {'error': error})


def logout_view(request):
    logout(request)
    return redirect('developer:login')


def _get_profile(user):
    return get_object_or_404(DeveloperProfile, user=user)


@login_required(login_url='/dev/login/')
def dashboard_view(request):
    profile = _get_profile(request.user)
    games = profile.games.all()
    stats = {
        'total': games.count(),
        'pending': games.filter(status=GameSubmission.Status.PENDING).count(),
        'published': games.filter(status=GameSubmission.Status.PUBLISHED).count(),
        'earnings': profile.total_earnings,
    }
    return render(request, 'developer/dashboard.html', {
        'profile': profile,
        'games': games[:5],
        'stats': stats,
    })


@login_required(login_url='/dev/login/')
def games_list_view(request):
    profile = _get_profile(request.user)
    games = profile.games.all()
    return render(request, 'developer/games_list.html', {
        'profile': profile,
        'games': games,
    })


@login_required(login_url='/dev/login/')
def game_create_view(request):
    profile = _get_profile(request.user)
    form = GameSubmissionForm(request.POST or None, request.FILES or None)
    if request.method == 'POST' and form.is_valid():
        game = form.save(commit=False)
        game.developer = profile
        if 'submit' in request.POST:
            game.status = GameSubmission.Status.PENDING
            game.submitted_at = timezone.now()
        game.save()
        return redirect('developer:game_detail', game_id=game.pk)
    return render(request, 'developer/game_form.html', {
        'form': form,
        'profile': profile,
        'editing': False,
    })


@login_required(login_url='/dev/login/')
def game_detail_view(request, game_id):
    profile = _get_profile(request.user)
    game = get_object_or_404(GameSubmission, pk=game_id, developer=profile)
    stats = None
    if game.game_id:
        from apps.platform.models import GameSession
        from django.db.models import Count, Sum, Avg
        catalog_game = game.game
        session_stats = GameSession.objects.filter(game=catalog_game).aggregate(
            total_sessions=Count('id'),
            total_playtime=Sum('duration_seconds'),
            avg_score=Avg('score'),
        )
        stats = {
            'play_count': catalog_game.play_count,
            'avg_rating': catalog_game.avg_rating,
            'ratings_count': catalog_game.ratings_count,
            'active_players': catalog_game.active_players,
            'total_sessions': session_stats['total_sessions'] or 0,
            'total_playtime_hours': round((session_stats['total_playtime'] or 0) / 3600, 1),
            'avg_score': round(session_stats['avg_score'] or 0),
        }
    return render(request, 'developer/game_detail.html', {
        'game': game,
        'profile': profile,
        'stats': stats,
    })


@login_required(login_url='/dev/login/')
def game_edit_view(request, game_id):
    profile = _get_profile(request.user)
    game = get_object_or_404(GameSubmission, pk=game_id, developer=profile)
    if game.status not in (GameSubmission.Status.DRAFT, GameSubmission.Status.REJECTED):
        return redirect('developer:game_detail', game_id=game.pk)
    form = GameSubmissionForm(request.POST or None, request.FILES or None, instance=game)
    if request.method == 'POST' and form.is_valid():
        game = form.save(commit=False)
        if 'submit' in request.POST:
            game.status = GameSubmission.Status.PENDING
            game.submitted_at = timezone.now()
        else:
            game.status = GameSubmission.Status.DRAFT
        game.rejection_reason = ''
        game.save()
        return redirect('developer:game_detail', game_id=game.pk)
    return render(request, 'developer/game_form.html', {
        'form': form,
        'game': game,
        'profile': profile,
        'editing': True,
    })


@login_required(login_url='/dev/login/')
def guide_view(request):
    profile = _get_profile(request.user)
    return render(request, 'developer/guide.html', {'profile': profile})


@login_required(login_url='/dev/login/')
def profile_view(request):
    profile = _get_profile(request.user)
    form = ProfileForm(request.POST or None, instance=profile)
    if request.method == 'POST' and form.is_valid():
        form.save()
        return redirect('developer:dashboard')
    return render(request, 'developer/profile.html', {
        'form': form,
        'profile': profile,
    })
