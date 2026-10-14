#!/bin/bash
# Copied from mem0 v2.2.1 server/init-db.sh. Creates the mem0_app database (users, API keys, audit log);
# memories themselves live in the default "postgres" database via pgvector.
set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "${POSTGRES_DB:-$POSTGRES_USER}" <<-EOSQL
    SELECT 'CREATE DATABASE mem0_app'
    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'mem0_app')\gexec
EOSQL
