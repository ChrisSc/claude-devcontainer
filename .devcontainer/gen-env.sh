#!/usr/bin/env bash
#
# gen-env.sh — create the gitignored secret files the compose services load, the
# first time each is needed. Idempotent per file: an existing file is left
# untouched (so its password stays stable across rebuilds), only re-chmodded.
#
#   .env         Postgres password. compose loads it into BOTH the `db` sidecar
#                (POSTGRES_*) and `claude-code` (PG* + DATABASE_URL), so the code
#                container can reach the DB with no manual credential handling.
#   pgadmin.env  pgAdmin's web login. Loaded ONLY by the `pgadmin` service — kept
#                out of .env so it isn't injected into claude-code/db, and so an
#                existing .env never needs rewriting to gain it.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$DIR/.env"
PGADMIN_ENV_FILE="$DIR/pgadmin.env"

# exists_keep FILE — true (and re-secures perms) if FILE already exists.
exists_keep() {
    [ -f "$1" ] || return 1
    # Re-secure perms even on the keep-it path: an older run (or a manual edit)
    # may have left the secret world-readable (644). chmod is idempotent.
    chmod 600 "$1"
    echo "[gen-env] $1 exists — leaving contents untouched (perms 600)"
}

umask 077

if ! exists_keep "$ENV_FILE"; then
    # hex => URL-safe + shell-safe (no /, +, = that would break DATABASE_URL).
    PW="$(openssl rand -hex 24)"
    DB_USER="claude"
    DB_NAME="claude"

    cat > "$ENV_FILE" <<EOF
# Auto-generated DB secrets for the claude sandbox. GITIGNORED — never commit.
# Stable once generated. To rotate: delete this file, run \`make env\`, then
# \`make db-reset\` (the password only takes effect on a fresh data volume) and
# \`make pgadmin-reset\` (pgAdmin imported the old password on its first start).

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
fi

if ! exists_keep "$PGADMIN_ENV_FILE"; then
    cat > "$PGADMIN_ENV_FILE" <<EOF
# Auto-generated pgAdmin web login (http://localhost:5050). GITIGNORED — never
# commit. Applied only on first init of the claude-pgadmin volume: after editing
# or deleting this file, \`make pgadmin-reset\` to make the change take effect.
# The address is a login name only (no mail is sent); example.com is reserved
# and passes pgAdmin's address validation, which rejects .local/.test names.
PGADMIN_DEFAULT_EMAIL=claude@example.com
PGADMIN_DEFAULT_PASSWORD=$(openssl rand -hex 24)
EOF
    chmod 600 "$PGADMIN_ENV_FILE"
    echo "[gen-env] wrote $PGADMIN_ENV_FILE (strong password generated)"
fi
