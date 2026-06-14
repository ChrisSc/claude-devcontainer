# shellcheck shell=bash
#
# log-event.sh — tiny shared structured-event helper for the boot pipeline.
#
# SOURCED (not executed) by entrypoint.sh, init-firewall.sh, seed-claude.sh and
# init-cron.sh. Appends one JSON object per line to a persistent JSONL journal on
# the claude-config volume so the boot sequence leaves a queryable, timestamped
# trail that survives the process (the console `echo`/`log()` lines stay as the
# dev mirror). Every append is FIRE-AND-FORGET (`>> file || true`): logging must
# never block or fail the boot it is observing.
#
# Event shape: {"ts","seq","boot_id","phase","event", ...payload}
#   ts       ISO-8601 UTC, millisecond precision (date -u +%FT%T.%3NZ)
#   seq      monotonic counter, shared across the whole boot via a counter file
#            keyed on boot_id (so entrypoint + the per-phase child scripts all
#            advance the same sequence — no gaps, no resets between processes)
#   boot_id  generated once in entrypoint.sh, exported, and threaded into the
#            devcontainer postStartCommand re-run so the two boots correlate
#   phase    the boot phase emitting the event (entrypoint|firewall|seed|cron)
#   event    dot-namespaced type, e.g. firewall.apply.start, seed.ssh.linked
#
# No `set -e` toggling here — the helper is sourced into scripts that already run
# `set -euo pipefail`, and every command below is guarded so a logging failure is
# swallowed, never propagated.

# Resolve the journal location. init-firewall.sh runs as root via sudo (env_reset
# strips CLAUDE_CONFIG_DIR), so fall back to the known claude home rather than
# root's. CLAUDE_LOG_USER is the owner the volume must keep.
CLAUDE_LOG_USER="${CLAUDE_LOG_USER:-claude}"
_log_event_config_dir() {
    if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
        printf '%s\n' "$CLAUDE_CONFIG_DIR"
    else
        printf '%s\n' "/home/${CLAUDE_LOG_USER}/.claude"
    fi
}

# A JSON string escaper for the small set of values we emit (event names, phases,
# and short payload strings). Handles the characters JSON requires: backslash,
# double-quote, and control chars (newline/tab/carriage-return). Keeps the helper
# dependency-free (no jq needed on the hot boot path).
_log_event_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/\\r}"
    printf '%s' "$s"
}

# log_event PHASE EVENT [k1 v1 [k2 v2 ...]]
#
# Emits one JSONL line. Extra key/value pairs become string payload fields. All
# failures are swallowed: a missing volume, a read-only FS, or a busy counter file
# must never abort the boot.
log_event() {
    local phase="$1" event="$2"
    shift 2 || true

    local cfg logs_dir journal counter_file seq ts line payload=""
    cfg="$(_log_event_config_dir)"
    logs_dir="${cfg}/logs"
    journal="${logs_dir}/boot-events.jsonl"

    # Best-effort scaffolding; if it fails we simply don't log.
    mkdir -p "$logs_dir" 2>/dev/null || return 0

    # Monotonic sequence shared across the boot. Keyed on boot_id so a re-run
    # (postStartCommand) under the SAME boot_id keeps counting up rather than
    # restarting, and a brand-new boot starts its own file. The read-increment is
    # not atomic across racing processes, but the boot pipeline is sequential
    # (entrypoint -> firewall -> seed -> cron), so a collision is not expected;
    # `seq` exists for ordering within a boot, not as a lock.
    local boot_id="${BOOT_ID:-unknown}"
    counter_file="${logs_dir}/.seq.${boot_id}"
    seq="$(cat "$counter_file" 2>/dev/null || echo 0)"
    case "$seq" in
        ''|*[!0-9]*) seq=0 ;;
    esac
    seq=$((seq + 1))
    printf '%s\n' "$seq" > "$counter_file" 2>/dev/null || true

    ts="$(date -u +%FT%T.%3NZ 2>/dev/null || date -u +%FT%TZ)"

    # Optional payload key/value pairs -> JSON string fields.
    while [ "$#" -ge 2 ]; do
        payload="${payload},\"$(_log_event_json_escape "$1")\":\"$(_log_event_json_escape "$2")\""
        shift 2
    done

    line="{\"ts\":\"${ts}\",\"seq\":${seq},\"boot_id\":\"$(_log_event_json_escape "$boot_id")\",\"phase\":\"$(_log_event_json_escape "$phase")\",\"event\":\"$(_log_event_json_escape "$event")\"${payload}}"

    printf '%s\n' "$line" >> "$journal" 2>/dev/null || true

    # When sourced under sudo (init-firewall.sh runs as root), the journal +
    # counter would be root-owned and the `claude` user could no longer append.
    # Re-own anything we touched back to the volume owner. Best-effort.
    if [ "$(id -u 2>/dev/null || echo 1000)" = "0" ]; then
        chown "${CLAUDE_LOG_USER}:${CLAUDE_LOG_USER}" \
            "$logs_dir" "$journal" "$counter_file" 2>/dev/null || true
    fi
}
