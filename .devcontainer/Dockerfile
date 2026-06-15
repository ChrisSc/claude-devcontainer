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
#
# Base image is DIGEST-PINNED for a reproducible, tamper-evident foundation. The
# digest is the multi-arch manifest-list digest, so it still resolves per-arch
# (arm64 on Apple Silicon, amd64 on WSL2). Bump deliberately (the tag in the
# comment is the human-readable label for this digest):
#   docker buildx imagetools inspect node:24-bookworm   # -> new Digest
# Renovate/Dependabot can PR digest updates.
FROM node:24-bookworm@sha256:40ad9f3064e67d6860b4bc3fe1880b2953934fd6320ada990e45fe0efa6badd7

# Fail closed on broken `curl | sh` pipelines: without `-o pipefail`, a failed
# download upstream of the pipe is masked by the shell's exit status (hadolint
# DL4006). Applies to every RUN below, incl. the uv/Claude installer pipes.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG TZ=America/New_York
ENV TZ="${TZ}" \
    DEBIAN_FRONTEND=noninteractive \
    DEVCONTAINER=true \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# ---------------------------------------------------------------------------
# 1. Base system + developer apt packages (+ GitHub CLI from its official repo)
# ---------------------------------------------------------------------------
# BuildKit cache mounts keep the apt archive + lists across rebuilds so unchanged
# package sets aren't re-downloaded. `sharing=locked` serialises concurrent
# builds; the base image's `docker-clean` (which auto-purges the cache) is removed
# so the mount actually persists, and the in-layer `apt-get clean`/`rm -rf` is
# dropped (the cache lives in the mount, NOT the image layer — no size regression).
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    set -eux; \
    rm -f /etc/apt/apt.conf.d/docker-clean; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl gnupg; \
    # GitHub CLI repo (gh is not in Debian bookworm main). TLS authenticates the
    # host, not the key bytes — so verify the downloaded keyring contains GitHub's
    # published signing-key fingerprint before trusting it for apt (fails the build
    # on a swapped key from a compromised endpoint / rogue-CA MITM).
    install -m 0755 -d /etc/apt/keyrings; \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    GH_KEY_FPR=2C6106201985B60E6C7AC87323F3D4EA75716059; \
    gpg --show-keys --with-colons /etc/apt/keyrings/githubcli-archive-keyring.gpg \
        | awk -F: '/^fpr:/{print $10}' | grep -qx "$GH_KEY_FPR" \
        || { echo "ERROR: GitHub CLI key fingerprint $GH_KEY_FPR not found" >&2; exit 1; }; \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        # core
        git gh less procps sudo zsh man-db unzip wget gnupg2 cron \
        build-essential pkg-config python3 tzdata \
        # firewall
        iptables ipset iproute2 dnsutils aggregate \
        # everyday CLI (apt-provided)
        jq ripgrep fd-find bat fzf direnv htop ncdu tree nano vim \
    ; \
    # Pin the SYSTEM timezone to $TZ. The base image only had `ENV TZ` set, which
    # glibc CLI tools honor — but /etc/localtime stayed at Etc/UTC, so anything
    # reading the system clock files (not the env var) silently got UTC. Set both
    # so the env var and the system files agree (no split-brain timezone).
    ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime; \
    echo "${TZ}" > /etc/timezone; \
    # Debian ships these under alternate binary names — add the canonical ones.
    ln -sf "$(command -v fdfind)" /usr/local/bin/fd; \
    ln -sf "$(command -v batcat)" /usr/local/bin/bat

# PostgreSQL 18 client (psql, pg_dump, pg_dumpall, createdb) for the db sidecar.
# MUST match the server major: an older pg_dump refuses to dump a newer server
# ("server version: 18; pg_dump version: 15; aborting"). Debian only ships 15, so
# pull the client from the official PGDG apt repo.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    set -eux; \
    install -d /usr/share/postgresql-common/pgdg; \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
        -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc; \
    # Verify the PGDG signing-key fingerprint before trusting it for apt (same
    # rogue-CA/MITM rationale as the GitHub CLI key above).
    PGDG_KEY_FPR=B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8; \
    gpg --show-keys --with-colons /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
        | awk -F: '/^fpr:/{print $10}' | grep -qx "$PGDG_KEY_FPR" \
        || { echo "ERROR: PGDG key fingerprint $PGDG_KEY_FPR not found" >&2; exit 1; }; \
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(. /etc/os-release; echo "$VERSION_CODENAME")-pgdg main" \
        > /etc/apt/sources.list.d/pgdg.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends postgresql-client-18

# ---------------------------------------------------------------------------
# 2. Modern CLI toolbelt not in apt (eza, zoxide, starship, delta, btm, dust,
#    procs, sd, hyperfine, tokei, tealdeer, yq, lazygit). Arch-aware.
# ---------------------------------------------------------------------------
COPY install-tools.sh /usr/local/bin/install-tools.sh
# Cache cargo's registry + git db so cargo-binstall metadata/index isn't re-fetched
# on every rebuild (runs as root here -> /root/.cargo).
RUN --mount=type=cache,target=/root/.cargo/registry \
    --mount=type=cache,target=/root/.cargo/git \
    chmod +x /usr/local/bin/install-tools.sh && /usr/local/bin/install-tools.sh

# ---------------------------------------------------------------------------
# 3. zsh plugins (direct-source, no oh-my-zsh framework) cloned to a system path.
#    Pinned to release tags (NOT branch HEAD): these are sourced into every
#    interactive shell, so the exact code must be reproducible and tamper-evident.
#    The expected commit SHA for each tag is asserted after clone — a hijacked
#    upstream that re-points the tag fails the build. Bump the tag + SHA together.
# ---------------------------------------------------------------------------
ARG ZSH_AUTOSUGGESTIONS_TAG=v0.7.1
ARG ZSH_AUTOSUGGESTIONS_SHA=e52ee8ca55bcc56a17c828767a3f98f22a68d4eb
ARG ZSH_FAST_SYNTAX_TAG=v1.56
ARG ZSH_FAST_SYNTAX_SHA=5ecd353c81214f82bdeca5483fab6ccc5a2d5494
ARG ZSH_COMPLETIONS_TAG=0.36.0
ARG ZSH_COMPLETIONS_SHA=28c5bdcaf81bb89e56d0df8267d822c3b8aed9e0
RUN set -eux; \
    clone_pinned() { \
        git clone --depth 1 --branch "$2" "$1" "$3"; \
        got="$(git -C "$3" rev-parse HEAD)"; \
        [ "$got" = "$4" ] || { echo "ERROR: $1 $2 HEAD $got != expected $4" >&2; exit 1; }; \
    }; \
    clone_pinned https://github.com/zsh-users/zsh-autosuggestions \
        "$ZSH_AUTOSUGGESTIONS_TAG" /usr/share/zsh-plugins/zsh-autosuggestions \
        "$ZSH_AUTOSUGGESTIONS_SHA"; \
    clone_pinned https://github.com/zdharma-continuum/fast-syntax-highlighting \
        "$ZSH_FAST_SYNTAX_TAG" /usr/share/zsh-plugins/fast-syntax-highlighting \
        "$ZSH_FAST_SYNTAX_SHA"; \
    clone_pinned https://github.com/zsh-users/zsh-completions \
        "$ZSH_COMPLETIONS_TAG" /usr/share/zsh-plugins/zsh-completions \
        "$ZSH_COMPLETIONS_SHA"; \
    rm -rf /usr/share/zsh-plugins/*/.git

# ---------------------------------------------------------------------------
# 4. Global Node/TS tooling + Playwright (+ Chromium baked OUTSIDE any volume)
# ---------------------------------------------------------------------------
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global \
    PLAYWRIGHT_BROWSERS_PATH=/usr/local/share/ms-playwright \
    PATH=/usr/local/share/npm-global/bin:$PATH
# Pin pnpm + every global npm tool to an exact version (no floating `latest`), so
# the toolchain is reproducible build-to-build. `--ignore-scripts` blocks
# arbitrary install-script execution from these packages / their transitive trees
# (none of these CLIs need a postinstall to function). Bump deliberately.
ARG PNPM_VER=11.6.0
ARG TYPESCRIPT_VER=6.0.3
ARG TSX_VER=4.22.4
ARG ESLINT_VER=10.5.0
ARG PRETTIER_VER=3.8.4
ARG PYRIGHT_VER=1.1.410
# playwright npm version is pinned in lockstep with the Chromium pulled by
# `playwright install chromium` below — they must agree to avoid driver skew.
ARG PLAYWRIGHT_VER=1.60.0
# Cache the npm download cache across rebuilds (the in-layer `npm cache clean` is
# dropped — the cache lives in the BuildKit mount, not the image layer).
RUN --mount=type=cache,target=/root/.npm \
    set -eux; \
    mkdir -p "$NPM_CONFIG_PREFIX"; \
    corepack enable; \
    corepack prepare "pnpm@${PNPM_VER}" --activate; \
    npm install -g --ignore-scripts \
        "typescript@${TYPESCRIPT_VER}" \
        "tsx@${TSX_VER}" \
        "eslint@${ESLINT_VER}" \
        "prettier@${PRETTIER_VER}" \
        "pyright@${PYRIGHT_VER}" \
        "playwright@${PLAYWRIGHT_VER}"; \
    # Chromium + its system libs, into the baked (non-volume) browsers path
    playwright install-deps chromium; \
    playwright install chromium; \
    chmod -R a+rX "$PLAYWRIGHT_BROWSERS_PATH"

# ---------------------------------------------------------------------------
# 5. Eclipse Temurin (OpenJDK) 11 — required by the IBKR Client Portal Gateway
#    (`clientportal.gw`). Pinned to jdk-11.0.31+11 + per-arch SHA-256, pulled from
#    Adoptium's GitHub releases. (At RUNTIME the egress firewall blocks the Adoptium
#    API/CDN but allowlists GitHub release assets — moot here, the build runs
#    pre-firewall, but it's why GitHub is the chosen distribution channel.)
#    Do NOT bump to Java 17+: the gateway's bundled netty-4.1.15 reflectively
#    accesses java.nio.DirectByteBuffer — a harmless warning on 11, a fatal
#    InaccessibleObjectException on 17+ (would force --add-opens flags in run.sh).
#    Bump the version + BOTH arch checksums together (mismatch fails the build).
#    update-alternatives symlinks java/javac into /usr/bin (already on PATH), so
#    only JAVA_HOME needs an ENV — the load-bearing final PATH (below) is untouched.
# ---------------------------------------------------------------------------
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
      arm64) JDK_ARCH=aarch64; JDK_SHA=257f4d39e060658fc2eb89a803ca43b3f337e64e253f2d94ebae1d85c9ef5f69 ;; \
      amd64) JDK_ARCH=x64;     JDK_SHA=1e9de64586b519c0a981319489257cabedd9457599f3823424a87c3158fbe939 ;; \
      *) echo "ERROR: unsupported arch for JDK: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    url="https://github.com/adoptium/temurin11-binaries/releases/download/jdk-11.0.31%2B11/OpenJDK11U-jdk_${JDK_ARCH}_linux_hotspot_11.0.31_11.tar.gz"; \
    curl -fL -o /tmp/jdk11.tar.gz "$url"; \
    echo "${JDK_SHA}  /tmp/jdk11.tar.gz" | sha256sum -c -; \
    mkdir -p /usr/lib/jvm; \
    tar -xzf /tmp/jdk11.tar.gz -C /usr/lib/jvm; \
    rm /tmp/jdk11.tar.gz; \
    update-alternatives --install /usr/bin/java  java  /usr/lib/jvm/jdk-11.0.31+11/bin/java  1100; \
    update-alternatives --install /usr/bin/javac javac /usr/lib/jvm/jdk-11.0.31+11/bin/javac 1100
ENV JAVA_HOME=/usr/lib/jvm/jdk-11.0.31+11

# ---------------------------------------------------------------------------
# 6. Rename the base `node` user (uid/gid 1000) -> `claude`; wire sudo + dirs
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
# 7. Baked dotfiles (NOT under any volume path -> never shadowed) + seed + scripts
# ---------------------------------------------------------------------------
COPY --chown=claude:claude home/.zshrc /home/claude/.zshrc
COPY --chown=claude:claude home/.config/ /home/claude/.config/
COPY seed/CLAUDE.md /usr/local/share/claude-seed/CLAUDE.md
COPY seed/crontab /usr/local/share/claude-seed/crontab
COPY init-firewall.sh entrypoint.sh seed-claude.sh init-cron.sh log-event.sh \
     crontab-reload crontab-edit /usr/local/bin/
COPY config/extra-allowlist.txt /etc/claude-firewall/extra-allowlist.txt
# The tracked template is baked alongside the (gitignored) real allowlist so a
# raw `docker compose up --build` on a fresh clone — before gen-allowlist.sh has
# created the real file — still has a sane allowlist to fall back to. The COPY
# above still copies config/extra-allowlist.txt (gen-allowlist.sh / the build
# context guarantees it exists); init-firewall.sh reads this .example only when
# the real file is missing.
COPY config/extra-allowlist.txt.example /etc/claude-firewall/extra-allowlist.txt.example
# Normalize line endings + set exec bits. The CRLF strip is load-bearing for
# Windows/WSL hosts: if the repo is checked out with CRLF, scripts otherwise die
# with `bad interpreter: ...^M` and .zshrc/allowlist parse `\r`-tainted lines.
# Belt-and-suspenders with .gitattributes (which only helps once it's a git repo).
# The /usr/local/bin scripts are normalized + chmod'd in a single loop so
# adding a script means editing only the COPY list above, not three lists here.
RUN set -eux; \
    for f in /usr/local/bin/init-firewall.sh \
             /usr/local/bin/entrypoint.sh \
             /usr/local/bin/seed-claude.sh \
             /usr/local/bin/init-cron.sh \
             /usr/local/bin/log-event.sh \
             /usr/local/bin/crontab-reload \
             /usr/local/bin/crontab-edit; do \
        sed -i 's/\r$//' "$f"; \
        chmod +x "$f"; \
    done; \
    sed -i 's/\r$//' \
        /etc/claude-firewall/extra-allowlist.txt \
        /etc/claude-firewall/extra-allowlist.txt.example \
        /home/claude/.zshrc \
        /usr/local/share/claude-seed/CLAUDE.md \
        /usr/local/share/claude-seed/crontab; \
    find /home/claude/.config -type f -exec sed -i 's/\r$//' {} +

# ---------------------------------------------------------------------------
# 8. Per-user runtime: Python (uv), Claude Code (native installer + auto-update)
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
    VISUAL=vim

# Final runtime PATH, written out in full rather than prepending to $PATH. Section 4
# already ran `PATH=/usr/local/share/npm-global/bin:$PATH` for the build, so
# prepending npm-global again here listed it TWICE. Harmless for resolution, but the
# dup leaked into anything that snapshots the live env (e.g. cron.env). This explicit
# value matches entrypoint.sh's normalized PATH, so the baked env and the
# runtime-normalized env agree (and stay single-entry).
ENV PATH=/home/claude/.local/bin:/usr/local/share/npm-global/bin:/home/claude/.local/share/pnpm:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# uv (Astral) + a managed CPython 3.14 + ruff. `--default` adds generic `python`/
# `python3` shims to ~/.local/bin (first on PATH) so the bare commands resolve to
# 3.14, shadowing Debian's /usr/bin/python3 (3.11, left intact for build tooling).
# `--preview-features python-install-default` is the blessed opt-in for the
# (still-experimental) default-shim behavior and silences the build-log warning.
# uv installer pinned to a versioned URL (not the unversioned latest), fetched to
# a temp file then run — so a broken/partial download aborts the build (pipefail
# is on via SHELL, but fetch-then-run also avoids executing a half-script). Bump
# UV_VER deliberately. CPython 3.14 + ruff are pinned to exact versions too.
ARG UV_VER=0.11.21
ARG PYTHON_VER=3.14
ARG RUFF_VER=0.15.17
RUN set -eux; \
    curl -LsSf "https://astral.sh/uv/${UV_VER}/install.sh" -o /tmp/uv-install.sh; \
    sh /tmp/uv-install.sh; \
    rm -f /tmp/uv-install.sh; \
    uv python install "${PYTHON_VER}" --default --preview-features python-install-default; \
    uv tool install "ruff==${RUFF_VER}"

# Claude Code via the native installer (npm -g is deprecated). DELIBERATE
# DEVIATION (org pinning standard): the installer always fetches the newest
# release and the container auto-updates `claude` at every startup (entrypoint.sh
# step 3), so a hard version pin here would be immediately overwritten and only
# adds churn. We pin the *channel* to `stable` (not bleeding `latest`) and
# fetch-then-run so a broken download aborts the build instead of piping a
# half-script into bash.
RUN set -eux; \
    curl -fsSL https://claude.ai/install.sh -o /tmp/claude-install.sh; \
    bash /tmp/claude-install.sh stable; \
    rm -f /tmp/claude-install.sh

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["sleep", "infinity"]
