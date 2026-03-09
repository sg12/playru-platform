FROM python:3.11-slim

WORKDIR /app

RUN apt-get update && apt-get install -y \
    libpq-dev gcc curl \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt \
    && pip install --no-cache-dir gunicorn psycopg2

COPY . .

# Собираем статику при сборке образа (не нужна БД, dummy SECRET_KEY):
RUN DJANGO_SECRET_KEY=build-dummy \
    DJANGO_SETTINGS_MODULE=config.settings.production \
    POSTGRES_HOST=localhost \
    DJANGO_DB_PASSWORD=dummy \
    python manage.py collectstatic --noinput 2>/dev/null || true

RUN ls /app/staticfiles/admin/css/ && echo "OK: static files baked in"

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=10s --start-period=40s \
    CMD curl -f http://localhost:8000/api/v1/platform/health/ || exit 1

ENTRYPOINT ["/app/entrypoint.sh"]
