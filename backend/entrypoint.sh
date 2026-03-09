#!/bin/bash
set -e
export DJANGO_SETTINGS_MODULE=config.settings.production
echo "Running collectstatic..."
python manage.py collectstatic --noinput --clear
echo "Starting gunicorn..."
exec gunicorn config.wsgi:application \
  --bind 0.0.0.0:8000 \
  --workers 4 \
  --timeout 120 \
  --access-logfile -
