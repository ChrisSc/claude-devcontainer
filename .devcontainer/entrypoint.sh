#!/usr/bin/env bash
#
# entrypoint.sh — startup orchestration for the Claude sandbox. Runs as `claude`
# (sudo is used only to load the firewall). Ordering is load-bearing: the
# firewall must be up before `claude update` reaches downloads.claude.ai.
set -euo pipefail

# Make sure user-local + global tool bins are visible in this non-interactive shell.
export PATH="/home/claude/.local/bin:/usr/local/share/npm-global/bin:/home/claude/.local/share/pnpm:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Structured boot-event journal (fire-and-forget JSONL on the claude-config
# volume; the console lines below are the dev mirror). BOOT_ID is generated ONCE
# here and exported so every phase script shares one correlation id + one
# monotonic seq counter; the devcontainer postStartCommand re-run threads its own
# BOOT_ID so a VS Code boot is a distinct, correlatable run. See log-event.sh.
export BOOT_ID="${BOOT_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
# shellcheck source=/dev/null
. /usr/local/bin/log-event.sh 2>/dev/null || true
# Fallback no-op so a missing/unreadable helper can never break the boot path.
command -v log_event >/dev/null 2>&1 || log_event() { :; }

# 1. Egress firewall (root via NOPASSWD sudo). Retry to absorb transient DNS.
echo "[entrypoint] applying firewall (FIREWALL_MODE=${FIREWALL_MODE:-strict})"
log_event entrypoint entrypoint.start mode "${FIREWALL_MODE:-strict}"
if ! sudo -n true 2>/dev/null; then
    echo "[entrypoint] ERROR: passwordless sudo unavailable — cannot apply firewall" >&2
    exit 1
fi
for attempt in 1 2 3; do
    # Pass FIREWALL_MODE *and* BOOT_ID explicitly: sudoers `env_reset` strips the
    # ambient env, but an explicit `sudo VAR=val` assignment survives it. Without
    # the FIREWALL_MODE pass the script falls back to its `:-strict` default;
    # without BOOT_ID the firewall's own JSONL events land under a fresh id and
    # lose correlation with this boot.
    if sudo FIREWALL_MODE="${FIREWALL_MODE:-strict}" BOOT_ID="${BOOT_ID}" \
        /usr/local/bin/init-firewall.sh; then
        break
    fi
    echo "[entrypoint] WARN: firewall attempt ${attempt} failed; retrying" >&2
    log_event entrypoint firewall.retry attempt "${attempt}"
    [ "$attempt" -eq 3 ] && { echo "[entrypoint] ERROR: firewall failed to apply" >&2; log_event entrypoint firewall.failed; exit 1; }
done

# 2. Seed ~/.claude/CLAUDE.md (copy-if-missing) + always-fresh ENVIRONMENT.md.
/usr/local/bin/seed-claude.sh || { echo "[entrypoint] WARN: seed step failed (non-fatal)" >&2; log_event entrypoint seed.failed; }

# 3. Auto-update Claude Code (firewall already allows the update host). Bounded
#    + stdin detached: the update is explicitly non-essential (postStartCommand
#    and `claude update` re-run it), so a hung update must not stall the boot
#    path before `exec "$@"`.
echo "[entrypoint] checking for Claude Code updates"
log_event entrypoint update.start
if timeout 120 claude update < /dev/null; then
    log_event entrypoint update.complete
else
    echo "[entrypoint] WARN: claude update failed/timed out (non-fatal)" >&2
    log_event entrypoint update.failed
fi

# 4. Install the persisted crontab + start cron (scheduled Claude agents). After
#    the firewall so jobs that fire have egress; non-fatal so cron can't brick boot.
/usr/local/bin/init-cron.sh || { echo "[entrypoint] WARN: cron init failed (non-fatal)" >&2; log_event entrypoint cron.failed; }

# 5. Hand off to the container command (default: sleep infinity).
echo "[entrypoint] ready — claude $(claude --version 2>/dev/null || echo '?'); attach with: docker exec -it claude-code zsh -l"
log_event entrypoint entrypoint.ready
exec "$@"
