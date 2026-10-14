#!/bin/bash
# Runs once, on an empty data volume. Creates the agent roles with least privilege.
# Passwords come from the container environment (postgres.env) via psql variables, never from this file.
set -eo pipefail

psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  -v ro_pw="$AGENT_RO_PASSWORD" -v rw_pw="$AGENT_RW_PASSWORD" -v db="$POSTGRES_DB" <<'EOSQL'
CREATE ROLE agent_ro LOGIN PASSWORD :'ro_pw' CONNECTION LIMIT 10;
CREATE ROLE agent_rw LOGIN PASSWORD :'rw_pw' CONNECTION LIMIT 10;

ALTER ROLE agent_ro SET default_transaction_read_only = on;
ALTER ROLE agent_ro SET statement_timeout = '15s';
ALTER ROLE agent_rw SET statement_timeout = '15s';
ALTER ROLE agent_ro SET idle_in_transaction_session_timeout = '30s';
ALTER ROLE agent_rw SET idle_in_transaction_session_timeout = '30s';

-- Only the agent roles (and the superuser) may connect; nobody gets the public schema.
REVOKE ALL ON DATABASE :"db" FROM PUBLIC;
GRANT CONNECT ON DATABASE :"db" TO agent_ro, agent_rw;
REVOKE ALL ON SCHEMA public FROM PUBLIC;

-- Schema "demo" is owned by the superuser, so the agents can never DROP/ALTER/TRUNCATE its tables.
CREATE SCHEMA demo AUTHORIZATION CURRENT_USER;
GRANT USAGE ON SCHEMA demo TO agent_ro, agent_rw;

ALTER DEFAULT PRIVILEGES IN SCHEMA demo GRANT SELECT ON TABLES TO agent_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA demo GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO agent_rw;
ALTER DEFAULT PRIVILEGES IN SCHEMA demo GRANT USAGE, SELECT ON SEQUENCES TO agent_rw;
EOSQL
