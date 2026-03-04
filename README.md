# PlayRU Platform

Игровая платформа на базе Nakama + Django + PostgreSQL.

## Стек

- **Nakama** — игровой бэкенд (real-time multiplayer)
- **Django 4.2** — веб-платформа, каталог игр, Admin
- **PostgreSQL 15** — единая БД
- **Docker Compose** — локальная разработка

## Быстрый старт

```bash
cp .env.example .env
docker compose up -d
```

## Сервисы

| Сервис   | URL                     |
|----------|-------------------------|
| Django   | http://localhost:8000   |
| Nakama   | http://localhost:7350   |
| Nakama Console | http://localhost:7351 |
| Adminer  | http://localhost:8080   |
