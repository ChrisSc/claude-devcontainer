#!/usr/bin/env bash
#
# seed-claude.sh — populate ~/.claude with environment docs. Runs as `claude`.
#   * CLAUDE.md      : copy-if-missing from the baked seed (never clobber edits).
#   * ENVIRONMENT.md : regenerated every start with the live tool/version inventory.
set -euo pipefail

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

# Git-over-SSH: the key + ssh client config live in the persistent ~/.claude/ssh
# volume, but ~/.ssh itself is NOT a volume — so the ~/.ssh/config symlink that
# ssh actually reads is wiped on every rebuild. Re-link it each boot so a
# one-time key setup (keygen + `gh ssh-key add`) survives rebuilds untouched.
SSH_CONFIG="$CONFIG_DIR/ssh/config"
if [ -f "$SSH_CONFIG" ]; then
    install -d -m 700 "$HOME/.ssh"
    ln -sf "$SSH_CONFIG" "$HOME/.ssh/config"
    chmod 600 "$SSH_CONFIG"
    [ -f "$CONFIG_DIR/ssh/id_ed25519" ] && chmod 600 "$CONFIG_DIR/ssh/id_ed25519"
    echo "[seed] linked ~/.ssh/config -> $SSH_CONFIG"
fi

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

## Claude Code
- claude: $(ver claude --version)
- config dir: $CONFIG_DIR

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
EOF
echo "[seed] regenerated ENVIRONMENT.md"
