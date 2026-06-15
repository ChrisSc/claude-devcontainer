#!/usr/bin/env bash
#
# seed-claude.sh — populate ~/.claude with environment docs. Runs as `claude`.
#   * CLAUDE.md      : copy-if-missing from the baked seed (never clobber edits).
#   * ENVIRONMENT.md : regenerated every start with the live tool/version inventory.
set -euo pipefail

# Structured boot-event journal (fire-and-forget JSONL; the echo lines stay as the
# dev mirror). BOOT_ID is inherited from the entrypoint env (this runs as `claude`,
# no sudo, so no env_reset); a bare run gets `unknown`. See log-event.sh.
# shellcheck source=/dev/null
. /usr/local/bin/log-event.sh 2>/dev/null || true
command -v log_event >/dev/null 2>&1 || log_event() { :; }

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SEED_SRC="/usr/local/share/claude-seed/CLAUDE.md"

install -d -m 700 "$CONFIG_DIR"
# AWS_CONFIG_FILE / AWS_SHARED_CREDENTIALS_FILE (set in the Dockerfile) point here
# so `aws configure` / `aws sso login` persist into the ~/.claude volume. The CLI
# won't create the parent dir for a custom config path, so ensure it exists.
install -d -m 700 "$CONFIG_DIR/aws"

# Static, user-editable guidance: seed once, then leave alone.
if [ ! -e "$CONFIG_DIR/CLAUDE.md" ] && [ -f "$SEED_SRC" ]; then
    install -m 644 "$SEED_SRC" "$CONFIG_DIR/CLAUDE.md"
    echo "[seed] installed CLAUDE.md"
fi

# Git-over-SSH: the key, client config, AND learned host fingerprints all live in
# the persistent ~/.claude/ssh volume, but ~/.ssh itself is NOT a volume — so its
# contents are wiped on every rebuild. Point ~/.ssh at the volume dir each boot so
# a one-time key setup (keygen + `gh ssh-key add`) *and* accumulated known_hosts /
# known_hosts.old survive rebuilds untouched.
#
# A *directory* symlink (not per-file) is load-bearing: OpenSSH's UpdateHostKeys
# path (default `yes` since 8.5) and `ssh-keygen -R` rewrite known_hosts via
# temp-file + atomic rename into the file's dir. A per-file ~/.ssh/known_hosts
# symlink would be clobbered by that rename — replaced with a real file in the
# ephemeral ~/.ssh — silently reverting to non-persistence. Linking the whole dir
# keeps every rewrite inside the volume. Don't revert this to per-file symlinks.
SSH_DIR="$CONFIG_DIR/ssh"
install -d -m 700 "$SSH_DIR"
[ -L "$HOME/.ssh" ] || rm -rf "$HOME/.ssh"   # drop a plain dir from a prior build
ln -sfn "$SSH_DIR" "$HOME/.ssh"
[ -f "$SSH_DIR/config" ] && chmod 600 "$SSH_DIR/config"
[ -f "$SSH_DIR/id_ed25519" ] && chmod 600 "$SSH_DIR/id_ed25519"
echo "[seed] linked ~/.ssh -> $SSH_DIR"
log_event seed seed.ssh.linked target "$SSH_DIR"

ver() { command -v "$1" >/dev/null 2>&1 && "$@" 2>/dev/null | head -n1 || echo "n/a"; }

# Live snapshot — overwritten each boot so it never goes stale.
cat > "$CONFIG_DIR/ENVIRONMENT.md" <<EOF
# Live Environment Snapshot

Regenerated at container start by \`seed-claude.sh\`. See CLAUDE.md for guidance.

## Host
- Container: \`claude-code\` (compose project \`claude\`)
- OS / arch: $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Debian}") / $(uname -m)
- User: $(whoami) (HOME=$HOME), shell: ${SHELL:-zsh}
- Firewall mode: ${FIREWALL_MODE:-strict}

## Languages
- node: $(ver node --version)
- pnpm: $(ver pnpm --version)
- typescript (tsc): $(ver tsc --version)
- tsx: $(ver tsx --version)
- uv: $(ver uv --version)
- python (managed by uv): $(ver uv run python --version)
- ruff: $(ver ruff --version)
- pyright: $(ver pyright --version)
- java (Temurin OpenJDK, for clientportal.gw): $(command -v java >/dev/null 2>&1 && java -version 2>&1 | head -n1 || echo n/a)

## Claude Code
- claude: $(ver claude --version)
- config dir: $CONFIG_DIR

## Database (Postgres sidecar — opt-in via the \`db\` compose profile)
- DATABASE_URL: $([ -n "${DATABASE_URL:-}" ] && echo "set" || echo "unset (db profile not active / .env absent)")
- PGHOST: ${PGHOST:-unset}
- reachable: $(pg_isready -t1 >/dev/null 2>&1 && echo "yes (pg_isready)" || echo "no (sidecar down or not started)")

## Tooling
- ripgrep: $(ver rg --version) | fd: $(ver fd --version) | bat: $(ver bat --version)
- eza: $(ver eza --version) | zoxide: $(ver zoxide --version) | fzf: $(ver fzf --version)
- delta: $(ver delta --version) | lazygit: $(ver lazygit --version) | gh: $(ver gh --version)
- jq: $(ver jq --version) | yq: $(ver yq --version) | aws: $(ver aws --version)
- btm: $(ver btm --version) | dust: $(ver dust --version) | procs: $(ver procs --version)
- sd: $(ver sd --version) | hyperfine: $(ver hyperfine --version) | tokei: $(ver tokei --version)
- starship: $(ver starship --version)
- playwright: $(ver playwright --version)

## Persistent volumes (survive rebuilds; removed only by \`docker compose down -v\`)
- /workspace                          -> claude-workspace
- /home/claude/.claude                -> claude-config (this file lives here)
- /commandhistory                     -> claude-bashhistory
- /home/claude/.local/share/pnpm      -> claude-pnpm-store
- (db sidecar) /var/lib/postgresql/data -> claude-pgdata (only with the \`db\` profile)
EOF
echo "[seed] regenerated ENVIRONMENT.md"
log_event seed seed.environment.regenerated
