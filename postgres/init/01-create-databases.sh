#!/bin/sh
# Creates the n8n and waha roles/databases. Runs only when the data dir is empty.
# Env (from compose): POSTGRES_USER, N8N_DB_PASSWORD, WAHA_DB_PASSWORD.
set -eu

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres \
  -v n8n_pw="$N8N_DB_PASSWORD" -v waha_pw="$WAHA_DB_PASSWORD" <<'SQL'
CREATE ROLE n8n LOGIN PASSWORD :'n8n_pw';
CREATE DATABASE n8n OWNER n8n;
-- WAHA creates one extra database per namespace/session, so it needs CREATEDB.
CREATE ROLE waha LOGIN CREATEDB PASSWORD :'waha_pw';
CREATE DATABASE waha OWNER waha;
SQL
