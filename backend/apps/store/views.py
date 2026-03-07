from django.shortcuts import render, get_object_or_404, redirect

from apps.games.models import Game
from .forms import DeveloperApplicationForm


def home(request):
    genre = request.GET.get('genre')
    games = Game.objects.filter(status='published')
    if genre:
        games = games.filter(genre=genre)

    genres = (
        Game.objects.filter(status='published')
        .values_list('genre', flat=True)
        .distinct()
        .order_by('genre')
    )

    return render(request, 'store/home.html', {
        'games': games,
        'genres': genres,
        'selected_genre': genre or '',
    })


def game_detail(request, slug):
    game = get_object_or_404(Game, slug=slug, status='published')
    return render(request, 'store/game_detail.html', {'game': game})


def download(request):
    return render(request, 'store/download.html')


def developer_apply(request):
    if request.method == 'POST':
        form = DeveloperApplicationForm(request.POST)
        if form.is_valid():
            form.save()
            return redirect('store:apply_success')
    else:
        form = DeveloperApplicationForm()
    return render(request, 'store/developer_apply.html', {'form': form})


def apply_success(request):
    return render(request, 'store/apply_success.html')
