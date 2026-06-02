#!/usr/bin/env bash
#
# gen-allowlist.sh — ensure .devcontainer/config/extra-allowlist.txt exists the
# first time it's needed, by copying the tracked template
# (extra-allowlist.txt.example). Idempotent: if the file already exists it is left
# untouched (so your personal hosts/IPs survive rebuilds).
#
# The real file is gitignored (it may hold LAN IPs / private hosts) and is BOTH
# baked into the image (Dockerfile COPY) and bind-mounted read-only over
# /etc/claude-firewall/extra-allowlist.txt by compose. This preflight is what
# guarantees the bind-mount SOURCE exists before compose creates the container:
# Docker Desktop otherwise silently creates an empty *directory* at a missing
# bind-mount path, and init-firewall.sh would then read a directory and break.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ALLOWLIST="$DIR/config/extra-allowlist.txt"
TEMPLATE="$DIR/config/extra-allowlist.txt.example"

if [ -f "$ALLOWLIST" ]; then
    echo "[gen-allowlist] $ALLOWLIST exists — leaving it untouched"
    exit 0
fi

if [ ! -f "$TEMPLATE" ]; then
    echo "[gen-allowlist] ERROR: template $TEMPLATE is missing" >&2
    exit 1
fi

cp "$TEMPLATE" "$ALLOWLIST"
cat >&2 <<EOF
[gen-allowlist] ============================================================
[gen-allowlist] Created config/extra-allowlist.txt from the template.
[gen-allowlist] It allows AWS egress (@aws-ip-ranges) by default. REVIEW it
[gen-allowlist] before relying on egress — add the hosts/IPs you need, then
[gen-allowlist] re-apply with \`make firewall\` (or restart the container).
[gen-allowlist] ============================================================
EOF
