# syntax=docker/dockerfile:1
#
# Modernized Claude Code dev container — "claude-code".
# Base: Node 24 LTS on Debian bookworm (glibc, needed for Playwright/Chromium).
# Default interactive user: `claude` (renamed from the image's `node`, uid 1000).
#
# Multi-arch: node:24-bookworm is a multi-arch manifest, and every build step is
# arch-aware (git-delta via dpkg --print-architecture; install-tools.sh handles
# amd64 + arm64; uv/pnpm/cargo-binstall auto-resolve). Docker builds for the host
# arch by default, so this same Dockerfile produces arm64 on Apple Silicon and
# amd64 on Windows/WSL2 (Intel) — no --platform pin (one would force emulation).
#
# Everything in this image is installed at BUILD time, before the runtime egress
# firewall (init-firewall.sh) is applied — so build-time downloads are unrestricted.
FROM node:24-bookworm

ARG TZ=America/Los_Angeles
ENV TZ="${TZ}" \
    DEBIAN_FRONTEND=noninteractive \
    DEVCONTAINER=true \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# ---------------------------------------------------------------------------
# 1. Base system + developer apt packages (+ GitHub CLI from its official repo)
# ---------------------------------------------------------------------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl gnupg; \
    # GitHub CLI repo (gh is not in Debian bookworm main)
    install -m 0755 -d /etc/apt/keyrings; \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        # core
        git gh less procps sudo zsh man-db unzip wget gnupg2 \
        build-essential pkg-config python3 \
        # firewall
        iptables ipset iproute2 dnsutils aggregate \
        # everyday CLI (apt-provided)
        jq ripgrep fd-find bat fzf direnv htop ncdu tree nano vim \
    ; \
    # Debian ships these under alternate binary names — add the canonical ones.
    ln -sf "$(command -v fdfind)" /usr/local/bin/fd; \
    ln -sf "$(command -v batcat)" /usr/local/bin/bat; \
    apt-get clean; rm -rf /var/lib/apt/lists/*

# PostgreSQL 18 client (psql, pg_dump, pg_dumpall, createdb) for the db sidecar.
# MUST match the server major: an older pg_dump refuses to dump a newer server
# ("server version: 18; pg_dump version: 15; aborting"). Debian only ships 15, so
# pull the client from the official PGDG apt repo.
RUN set -eux; \
    install -d /usr/share/postgresql-common/pgdg; \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
        -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc; \
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(. /etc/os-release; echo "$VERSION_CODENAME")-pgdg main" \
        > /etc/apt/sources.list.d/pgdg.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends postgresql-client-18; \
    apt-get clean; rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# 2. Modern CLI toolbelt not in apt (eza, zoxide, starship, delta, btm, dust,
#    procs, sd, hyperfine, tokei, tealdeer, yq, lazygit). Arch-aware.
# ---------------------------------------------------------------------------
COPY install-tools.sh /usr/local/bin/install-tools.sh
RUN chmod +x /usr/local/bin/install-tools.sh && /usr/local/bin/install-tools.sh

# ---------------------------------------------------------------------------
# 3. zsh plugins (direct-source, no oh-my-zsh framework) cloned to a system path
# ---------------------------------------------------------------------------
RUN set -eux; \
    git clone --depth 1 https://github.com/zsh-users/zsh-autosuggestions \
        /usr/share/zsh-plugins/zsh-autosuggestions; \
    git clone --depth 1 https://github.com/zdharma-continuum/fast-syntax-highlighting \
        /usr/share/zsh-plugins/fast-syntax-highlighting; \
    git clone --depth 1 https://github.com/zsh-users/zsh-completions \
        /usr/share/zsh-plugins/zsh-completions; \
    rm -rf /usr/share/zsh-plugins/*/.git

# ---------------------------------------------------------------------------
# 4. Global Node/TS tooling + Playwright (+ Chromium baked OUTSIDE any volume)
# ---------------------------------------------------------------------------
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global \
    PLAYWRIGHT_BROWSERS_PATH=/usr/local/share/ms-playwright \
    PATH=/usr/local/share/npm-global/bin:$PATH
RUN set -eux; \
    mkdir -p "$NPM_CONFIG_PREFIX"; \
    corepack enable; \
    corepack prepare pnpm@latest --activate; \
    npm install -g typescript tsx eslint prettier pyright playwright; \
    # Chromium + its system libs, into the baked (non-volume) browsers path
    playwright install-deps chromium; \
    playwright install chromium; \
    chmod -R a+rX "$PLAYWRIGHT_BROWSERS_PATH"; \
    npm cache clean --force

# ---------------------------------------------------------------------------
# 5. Rename the base `node` user (uid/gid 1000) -> `claude`; wire sudo + dirs
# ---------------------------------------------------------------------------
ARG USERNAME=claude
RUN set -eux; \
    groupmod -n "$USERNAME" node; \
    usermod -l "$USERNAME" -d "/home/$USERNAME" -m node; \
    usermod -s /usr/bin/zsh "$USERNAME"; \
    # passwordless sudo (personal isolated box — see seed CLAUDE.md for the trade-off)
    echo "$USERNAME ALL=(root) NOPASSWD: ALL" > /etc/sudoers.d/"$USERNAME"; \
    chmod 0440 /etc/sudoers.d/"$USERNAME"; \
    visudo -cf /etc/sudoers.d/"$USERNAME"; \
    # persistent-volume mount points + claude home dirs, owned up front so empty
    # named volumes inherit correct ownership on first mount
    mkdir -p \
        /workspace \
        /commandhistory \
        /etc/claude-firewall \
        "/home/$USERNAME/.claude" \
        "/home/$USERNAME/.cache" \
        "/home/$USERNAME/.config" \
        "/home/$USERNAME/.local/bin" \
        "/home/$USERNAME/.local/share/pnpm"; \
    touch /commandhistory/.zsh_history; \
    chown -R "$USERNAME:$USERNAME" \
        /workspace /commandhistory \
        "/home/$USERNAME" \
        /usr/local/share/npm-global

# ---------------------------------------------------------------------------
# 6. Baked dotfiles (NOT under any volume path -> never shadowed) + seed + scripts
# ---------------------------------------------------------------------------
COPY --chown=claude:claude home/.zshrc /home/claude/.zshrc
COPY --chown=claude:claude home/.config/ /home/claude/.config/
COPY seed/CLAUDE.md /usr/local/share/claude-seed/CLAUDE.md
COPY init-firewall.sh entrypoint.sh seed-claude.sh /usr/local/bin/
COPY config/extra-allowlist.txt /etc/claude-firewall/extra-allowlist.txt
# Normalize line endings + set exec bits. The CRLF strip is load-bearing for
# Windows/WSL hosts: if the repo is checked out with CRLF, scripts otherwise die
# with `bad interpreter: ...^M` and .zshrc/allowlist parse `\r`-tainted lines.
# Belt-and-suspenders with .gitattributes (which only helps once it's a git repo).
RUN set -eux; \
    sed -i 's/\r$//' \
        /usr/local/bin/init-firewall.sh \
        /usr/local/bin/entrypoint.sh \
        /usr/local/bin/seed-claude.sh \
        /etc/claude-firewall/extra-allowlist.txt \
        /home/claude/.zshrc \
        /usr/local/share/claude-seed/CLAUDE.md; \
    find /home/claude/.config -type f -exec sed -i 's/\r$//' {} +; \
    chmod +x /usr/local/bin/init-firewall.sh \
             /usr/local/bin/entrypoint.sh \
             /usr/local/bin/seed-claude.sh

# ---------------------------------------------------------------------------
# 7. Per-user runtime: Python (uv), Claude Code (native installer + auto-update)
# ---------------------------------------------------------------------------
USER claude
ENV HOME=/home/claude \
    CLAUDE_CONFIG_DIR=/home/claude/.claude \
    GH_CONFIG_DIR=/home/claude/.claude/gh \
    GIT_CONFIG_GLOBAL=/home/claude/.claude/gitconfig \
    AWS_CONFIG_FILE=/home/claude/.claude/aws/config \
    AWS_SHARED_CREDENTIALS_FILE=/home/claude/.claude/aws/credentials \
    PNPM_HOME=/home/claude/.local/share/pnpm \
    NODE_OPTIONS=--max-old-space-size=4096 \
    TEALDEER_CACHE_DIR=/usr/local/share/tealdeer \
    SHELL=/usr/bin/zsh \
    EDITOR=vim \
    VISUAL=vim \
    PATH=/home/claude/.local/bin:/usr/local/share/npm-global/bin:/home/claude/.local/share/pnpm:$PATH

# uv (Astral) + a managed CPython 3.14 + ruff. `--default` adds generic `python`/
# `python3` shims to ~/.local/bin (first on PATH) so the bare commands resolve to
# 3.14, shadowing Debian's /usr/bin/python3 (3.11, left intact for build tooling).
# `--preview-features python-install-default` is the blessed opt-in for the
# (still-experimental) default-shim behavior and silences the build-log warning.
RUN set -eux; \
    curl -LsSf https://astral.sh/uv/install.sh | sh; \
    uv python install 3.14 --default --preview-features python-install-default; \
    uv tool install ruff

# Claude Code via the native installer (npm -g is deprecated); auto-updates at startup.
RUN curl -fsSL https://claude.ai/install.sh | bash

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["sleep", "infinity"]
