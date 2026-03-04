#!/bin/bash
set -e

# Create nakama user and database
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE USER nakama_user WITH PASSWORD '${NAKAMA_DB_PASSWORD:-changeme}';
    CREATE DATABASE nakama;
    GRANT ALL PRIVILEGES ON DATABASE nakama TO nakama_user;

    CREATE USER django_user WITH PASSWORD '${DJANGO_DB_PASSWORD:-changeme}' CREATEDB;
    CREATE DATABASE playru;
    GRANT ALL PRIVILEGES ON DATABASE playru TO django_user;

    -- Grant schema permissions for Django
    \c playru
    GRANT ALL ON SCHEMA public TO django_user;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO django_user;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO django_user;
EOSQL
