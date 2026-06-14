#!/usr/bin/env bash
#
# init-cron.sh — install the persisted crontab into the live cron spool and start
# the cron daemon, for scheduled Claude agents. Runs as `claude` (sudo only to
# start the root daemon). Mirrors init-firewall.sh's "degrade, never brick" style.
#
# Why this exists: per-user crontabs live in /var/spool/cron/crontabs (container
# layer — wiped on rebuild), and Debian's Vixie cron refuses symlinked / wrong-perm
# crontab files, so a symlink into a volume is silently ignored. Instead the
# crontab is kept as a REAL file in the persistent ~/.claude volume and re-installed
# into the spool here at every boot (a regular file with correct perms).
#
# Invoked at startup (entrypoint.sh + devcontainer postStartCommand) and on demand
# (crontab-reload / crontab-edit). Idempotent: safe to re-run.
set -euo pipefail

# Structured boot-event journal (fire-and-forget JSONL; the log()/warn() console
# lines stay as the dev mirror). BOOT_ID is inherited from the entrypoint env
# (runs as `claude`, no env_reset); a bare reload gets `unknown`. See log-event.sh.
# shellcheck source=/dev/null
. /usr/local/bin/log-event.sh 2>/dev/null || true
command -v log_event >/dev/null 2>&1 || log_event() { :; }

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CRON_DIR="$CONFIG_DIR/cron"
CRONTAB_FILE="$CRON_DIR/crontab"
ENV_FILE="$CRON_DIR/cron.env"
LOG_DIR="$CRON_DIR/logs"
TEMPLATE="/usr/local/share/claude-seed/crontab"
CROND_BIN="$(command -v cron || echo /usr/sbin/cron)"

log()  { echo "[cron] $*"; }
warn() { echo "[cron] WARN: $*" >&2; }

# Preflight: degrade (don't brick) if the cron package isn't present.
if ! command -v crontab >/dev/null 2>&1 || [ ! -x "$CROND_BIN" ]; then
    warn "cron not installed — skipping scheduled-agent setup"
    log_event cron cron.degraded reason "cron not installed"
    exit 0
fi

# 1. Scaffolding in the persistent volume.
install -d -m 700 "$CRON_DIR" "$LOG_DIR"

# 2. Seed the crontab from the baked template, copy-if-missing (never clobber the
#    user's jobs). The template ships only env + comments => an empty job set, so a
#    fresh container has cron idle, not broken.
if [ ! -e "$CRONTAB_FILE" ] && [ -f "$TEMPLATE" ]; then
    install -m 600 "$TEMPLATE" "$CRONTAB_FILE"
    log "seeded $CRONTAB_FILE from template"
fi

# 3. Regenerate the job environment every boot (like seed-claude.sh's ENVIRONMENT.md).
#    cron runs jobs with a stripped env; the crontab sets SHELL=/bin/bash + BASH_ENV
#    to this file so every job sources the live `claude` environment (PATH, auth
#    paths, ...) without per-line boilerplate. Values are read from the live process,
#    but the NAMES are an explicit allowlist — add a new var here when you add a new
#    Dockerfile/compose ENV that cron jobs need (it is NOT auto-discovered).
#    The PG*/DATABASE_URL vars come from the db sidecar's .env; the ${!name:+x} guard
#    below skips them harmlessly when the `db` profile isn't running.
CRON_ENV_VARS=(
    PATH HOME
    CLAUDE_CONFIG_DIR GH_CONFIG_DIR GIT_CONFIG_GLOBAL
    AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE
    PNPM_HOME NODE_OPTIONS TEALDEER_CACHE_DIR
    NPM_CONFIG_PREFIX PLAYWRIGHT_BROWSERS_PATH
    PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE DATABASE_URL
    LANG LC_ALL TZ EDITOR VISUAL
)
{
    echo "# Sourced by cron jobs via BASH_ENV. Regenerated each boot by init-cron.sh."
    echo "# Do not edit — changes are overwritten. (Add jobs in ./crontab.)"
    for name in "${CRON_ENV_VARS[@]}"; do
        # ${!name:+x} is safe under set -u (no error for unset); skip empty vars.
        if [ -n "${!name:+x}" ]; then
            printf 'export %s=%q\n' "$name" "${!name}"
        fi
    done
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"
log "regenerated $ENV_FILE"

# 4. Install the persisted crontab into the live spool. Non-fatal on parse error
#    (degrade, never brick) — a bad line shouldn't stop the container from booting.
if [ -f "$CRONTAB_FILE" ]; then
    if crontab "$CRONTAB_FILE"; then
        # Count scheduled lines (start with a digit, '*', or '@') — not the
        # SHELL=/BASH_ENV=/comment lines, so an empty job set reports 0.
        job_lines="$(crontab -l 2>/dev/null | grep -cE '^[[:space:]]*[0-9*@]' || true)"
        log "installed crontab (${job_lines:-0} job line(s))"
        log_event cron cron.installed job_lines "${job_lines:-0}"
    else
        warn "crontab failed to install $CRONTAB_FILE (parse error?) — left previous spool in place"
        log_event cron cron.install.failed
    fi
fi

# 5. Start the daemon (root, so it can setuid to `claude` for each job). Guarded by
#    pgrep so a re-run (postStartCommand / crontab-reload) never double-starts it.
if pgrep -x cron >/dev/null 2>&1; then
    log "cron daemon already running"
    log_event cron cron.daemon.started state "already-running"
elif sudo -n "$CROND_BIN"; then
    log "started cron daemon"
    log_event cron cron.daemon.started state "started"
else
    warn "could not start cron daemon"
    log_event cron cron.daemon.failed
fi
