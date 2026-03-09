from django import forms
from django.contrib.auth.models import User

from .models import DeveloperProfile, GameSubmission

tw = 'w-full px-4 py-3 bg-slate-700 border border-slate-600 rounded-lg text-white placeholder-slate-400 focus:outline-none focus:border-blue-500 focus:ring-1 focus:ring-blue-500'
tw_select = 'w-full px-4 py-3 bg-slate-700 border border-slate-600 rounded-lg text-white focus:outline-none focus:border-blue-500 focus:ring-1 focus:ring-blue-500'


class RegisterForm(forms.Form):
    username = forms.CharField(
        max_length=150,
        widget=forms.TextInput(attrs={'class': tw, 'placeholder': 'Логин'}),
    )
    email = forms.EmailField(
        widget=forms.EmailInput(attrs={'class': tw, 'placeholder': 'Email'}),
    )
    display_name = forms.CharField(
        max_length=100,
        widget=forms.TextInput(attrs={'class': tw, 'placeholder': 'Отображаемое имя'}),
    )
    password = forms.CharField(
        widget=forms.PasswordInput(attrs={'class': tw, 'placeholder': 'Пароль'}),
    )
    password_confirm = forms.CharField(
        widget=forms.PasswordInput(attrs={'class': tw, 'placeholder': 'Подтвердите пароль'}),
    )

    def clean_username(self):
        username = self.cleaned_data['username']
        if User.objects.filter(username=username).exists():
            raise forms.ValidationError('Пользователь с таким логином уже существует.')
        return username

    def clean_email(self):
        email = self.cleaned_data['email']
        if User.objects.filter(email=email).exists():
            raise forms.ValidationError('Пользователь с таким email уже существует.')
        return email

    def clean(self):
        cleaned = super().clean()
        if cleaned.get('password') != cleaned.get('password_confirm'):
            self.add_error('password_confirm', 'Пароли не совпадают.')
        return cleaned


class GameSubmissionForm(forms.ModelForm):
    MAX_PCK_SIZE = 50 * 1024 * 1024  # 50 MB

    class Meta:
        model = GameSubmission
        fields = ['title', 'slug', 'description', 'genre', 'min_age',
                  'godot_repo_url', 'nakama_module_name', 'pck_file', 'entry_scene']
        widgets = {
            'title': forms.TextInput(attrs={'class': tw, 'placeholder': 'Название игры'}),
            'slug': forms.TextInput(attrs={'class': tw, 'placeholder': 'slug-igry'}),
            'description': forms.Textarea(attrs={'class': tw, 'rows': 5, 'placeholder': 'Описание игры'}),
            'genre': forms.Select(attrs={'class': tw_select}),
            'min_age': forms.NumberInput(attrs={'class': tw, 'min': 0}),
            'godot_repo_url': forms.URLInput(attrs={'class': tw, 'placeholder': 'https://github.com/...'}),
            'nakama_module_name': forms.TextInput(attrs={'class': tw, 'placeholder': 'my_game_module'}),
            'pck_file': forms.ClearableFileInput(attrs={'class': tw, 'accept': '.pck'}),
            'entry_scene': forms.TextInput(attrs={'class': tw, 'placeholder': 'res://MyGame.tscn'}),
        }

    def clean_pck_file(self):
        pck = self.cleaned_data.get('pck_file')
        if pck and pck.size > self.MAX_PCK_SIZE:
            raise forms.ValidationError(f'PCK файл слишком большой (макс. {self.MAX_PCK_SIZE // 1024 // 1024} МБ).')
        return pck

    GENRE_CHOICES = [
        ('', 'Выберите жанр'),
        ('action', 'Экшен'),
        ('adventure', 'Приключения'),
        ('puzzle', 'Головоломка'),
        ('strategy', 'Стратегия'),
        ('rpg', 'RPG'),
        ('simulation', 'Симулятор'),
        ('sports', 'Спорт'),
        ('racing', 'Гонки'),
        ('educational', 'Образовательная'),
        ('other', 'Другое'),
    ]

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.fields['genre'].widget = forms.Select(
            attrs={'class': tw_select},
            choices=self.GENRE_CHOICES,
        )


class ProfileForm(forms.ModelForm):
    class Meta:
        model = DeveloperProfile
        fields = ['display_name', 'bio']
        widgets = {
            'display_name': forms.TextInput(attrs={'class': tw}),
            'bio': forms.Textarea(attrs={'class': tw, 'rows': 4, 'placeholder': 'Расскажите о себе...'}),
        }
