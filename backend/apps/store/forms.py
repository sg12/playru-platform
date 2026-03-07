from django import forms

from .models import DeveloperApplication


class DeveloperApplicationForm(forms.ModelForm):
    class Meta:
        model = DeveloperApplication
        fields = ['name', 'email', 'game_description']
        widgets = {
            'name': forms.TextInput(attrs={
                'class': 'w-full bg-gray-800 border border-gray-600 rounded-lg px-4 py-3 text-white placeholder-gray-400 focus:outline-none focus:border-purple-500',
                'placeholder': 'Ваше имя',
            }),
            'email': forms.EmailInput(attrs={
                'class': 'w-full bg-gray-800 border border-gray-600 rounded-lg px-4 py-3 text-white placeholder-gray-400 focus:outline-none focus:border-purple-500',
                'placeholder': 'email@example.com',
            }),
            'game_description': forms.Textarea(attrs={
                'class': 'w-full bg-gray-800 border border-gray-600 rounded-lg px-4 py-3 text-white placeholder-gray-400 focus:outline-none focus:border-purple-500',
                'placeholder': 'Расскажите о вашей игре или идее...',
                'rows': 5,
            }),
        }
