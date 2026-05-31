#!/usr/bin/env bash
#
# gen-env.sh — create .devcontainer/.env with a strong, randomly-generated
# Postgres password the first time it's needed. Idempotent: if .env already
# exists it is left untouched (so the password stays stable across rebuilds).
#
# The file is gitignored and holds the DB secret. compose loads it into BOTH the
# `db` sidecar (POSTGRES_*) and `claude-code` (PG* + DATABASE_URL), so the code
# container can reach the DB with no manual credential handling.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$DIR/.env"

if [ -f "$ENV_FILE" ]; then
    echo "[gen-env] $ENV_FILE exists — leaving it untouched"
    exit 0
fi

# hex => URL-safe + shell-safe (no /, +, = that would break DATABASE_URL).
PW="$(openssl rand -hex 24)"
DB_USER="claude"
DB_NAME="claude"

umask 077
cat > "$ENV_FILE" <<EOF
# Auto-generated DB secrets for the claude sandbox. GITIGNORED — never commit.
# Stable once generated. To rotate: delete this file, run \`make env\`, then
# \`make db-reset\` (the password only takes effect on a fresh data volume).

# --- consumed by the db sidecar (official postgres entrypoint) ---
POSTGRES_USER=${DB_USER}
POSTGRES_PASSWORD=${PW}
POSTGRES_DB=${DB_NAME}

# --- injected into claude-code (libpq vars + URL; psql/pg_dump auto-connect) ---
PGHOST=db
PGPORT=5432
PGUSER=${DB_USER}
PGPASSWORD=${PW}
PGDATABASE=${DB_NAME}
DATABASE_URL=postgresql://${DB_USER}:${PW}@db:5432/${DB_NAME}
EOF
chmod 600 "$ENV_FILE"
echo "[gen-env] wrote $ENV_FILE (strong password generated)"
