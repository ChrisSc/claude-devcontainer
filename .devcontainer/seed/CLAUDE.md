# This Container — Claude's Home

This is your environment. It's seeded once; edit it freely. A live, always-fresh
companion (`~/.claude/ENVIRONMENT.md`) is regenerated every boot with exact
versions and the current firewall mode — consult it when you need specifics.

> This file documents the **environment** (what's installed, how the sandbox
> behaves). If you keep a global or project `CLAUDE.md` with code-style rules,
> that governs **how to write code** — don't duplicate style rules here.

## 1. What this machine is
- A security-sandboxed dev container — your long-lived home. Safe to use as a
  scratch and work environment.
- OS: **Debian bookworm**, base image `node:24`. Arch depends on the host —
  **arm64** on Apple Silicon, **amd64** on Windows/WSL2 (Intel). Check
  `~/.claude/ENVIRONMENT.md` (or `uname -m`) for the running arch; install
  binaries for that arch, not a hardcoded one.
- User: **`claude`**, with **passwordless `sudo`** (this is a single-user
  isolated box; sudo is unrestricted for convenience — be deliberate with it).
- Shell: **zsh** with the **starship** prompt.

## 2. The network is locked down (read this first)
A **default-deny egress firewall** (iptables + ipset `allowed-domains`) is
active. Most outbound connections FAIL unless the host is allowlisted.
- **A connection timeout / "could not resolve" is almost always the firewall —
  not a bug in your code.**
- Inspect what's reachable: `sudo ipset list allowed-domains`.
- Allowed out of the box: Anthropic API/auth/update, npm + pnpm, Python via uv
  (PyPI, pythonhosted, astral.sh, GitHub release assets), GitHub clone/release,
  Playwright browser CDN, VS Code.
- **Blocked:** arbitrary `curl` / WebFetch / WebSearch to non-allowlisted
  domains.
- **Add a domain:** append a hostname to
  `/etc/claude-firewall/extra-allowlist.txt` (editable from the host), then
  `sudo /usr/local/bin/init-firewall.sh`.
- **Open the web entirely:** restart with `FIREWALL_MODE=permissive` (see the
  banner at shell login / ENVIRONMENT.md for the current mode).
- **Intermittent download failures** (pip/uv/playwright) usually mean a CDN
  rotated to an IP captured-at-boot. Re-run `sudo /usr/local/bin/init-firewall.sh`
  to refresh.
- **Failure signature — `no route to host` / connect timeout, but the name
  resolves:** that's this firewall's `REJECT`, not a network outage. `dig` always
  works (DNS is allowed); the `:443` connect is being dropped because the IP
  isn't in the allowlist. Allowlist the host (above) and re-run the firewall.
  Re-running is safe and idempotent — do it whenever egress looks wrong.
- **Degraded mode:** if the host kernel lacks iptables/ipset (some Windows/WSL2
  kernels), the firewall self-disables at boot with a `FIREWALL DEGRADED` banner
  and egress is **unrestricted**. Check the startup log / `ENVIRONMENT.md` if
  unsure whether filtering is active. The fix is host-side: use Docker's WSL2
  backend.

## 3. Shell aliases & gotchas
- Active interactive aliases: `ls`→eza, `ll`/`la`/`lt`/`tree`, `cat`→bat
  (`--paging=never`), `cd`→z (zoxide), `top`→btm, `lg`→lazygit, `py`→`uv run python`.
- Gotcha: `ls`/`cat` are aliased — output differs from coreutils. For raw
  output use `command ls` / `command cat` (or `catp`).
- `grep` / `find` / `ps` / `du` are **NOT** aliased — call `rg` / `fd` / `procs`
  / `dust` by name.
- Aliases apply to interactive shells only; scripts and `/bin/sh` get the real
  tools.

## 4. Installed tools (by category)
- **Search/files:** `rg` (grep), `fd` (find), `fzf` (fuzzy finder), `bat`
  (cat+syntax), `eza` (ls), `z`/`zoxide` (smart cd), `sd` (sed), `dust` (disk
  usage), `procs` (ps), `btm` (system monitor), `tree`, `ncdu`, `htop`.
- **Data/text:** `jq` (JSON), `yq` (YAML/XML), `delta` (git diff pager).
- **Git/dev:** `git`, `gh` (GitHub CLI), `lazygit`/`lg` (git TUI).
- **Perf/insight:** `hyperfine` (benchmark), `tokei` (LOC count).
- **Docs:** `tldr` (concise examples — `tldr <cmd>`).
- **Editors:** `vim`, `nano`. **Prompt:** `starship`.

## 5. Language toolchains (how to invoke)
- **Python — use `uv` for everything; never bare `pip`.**
  - Run a script: `uv run script.py`
  - One-off tool: `uvx ruff check` / `uvx <tool>`
  - Deps: `uv add <pkg>` / `uv sync`
  - Interpreter: bare `python`/`python3` resolve to the uv-managed CPython 3.14
    (default shim in `~/.local/bin`). `uv python install <ver>` adds more.
  - Lint+format: `ruff`. Type-check: `pyright`.
  - Debian's `/usr/bin/python3` (3.11) still exists for build tooling (node-gyp)
    but is shadowed on PATH — prefer `uv run`/project venvs for real work.
- **Node / TypeScript — Node 24.**
  - Package manager: **`pnpm`** (via corepack).
  - Run TS directly: **`tsx file.ts`**. Compile: `tsc`. Lint: `eslint`. Format:
    `prettier`.
- **Browser automation:** Playwright is installed and Chromium is **baked in**
  (`PLAYWRIGHT_BROWSERS_PATH=/usr/local/share/ms-playwright`). Launch headless;
  no download needed.

## 6. Where data persists
Named volumes survive rebuilds (removed only by `docker compose down -v`):
- `/workspace` → your code. Isolated volume; clone projects in (GitHub allowed).
- `~/.claude` → Claude config, auth, this file, **added skills**, gh + git config.
- `/commandhistory` → shell history. `~/.local/share/pnpm` → pnpm store.

Everything **outside** those paths lives in the container layer: it survives
stop/start but is **wiped on rebuild** (`make rebuild` / `docker compose down`).
A folder you make in `~/` (e.g. `~/projects`) vanishes on the next rebuild — keep
all durable work in `/workspace`.

## 7. Credentials (isolated)
No host credentials are mounted. Authenticate once inside; it persists in the
`~/.claude` volume:
- `gh auth login` (config in `$GH_CONFIG_DIR=~/.claude/gh`).
- `git config --global user.name/user.email` (`$GIT_CONFIG_GLOBAL=~/.claude/gitconfig`).
- AWS: the `aws` CLI (v2) is baked into the image. `aws configure` / `aws sso
  login` write to `$AWS_CONFIG_FILE=~/.claude/aws/config` +
  `$AWS_SHARED_CREDENTIALS_FILE=~/.claude/aws/credentials`, so creds persist in the
  volume across rebuilds. Runtime egress to AWS APIs is allowed via the firewall's
  `@aws-ip-ranges` directive (see `config/extra-allowlist.txt`).
- SSH for git: keep the key in the persistent `~/.claude/ssh/` volume — `~/.ssh`
  itself is NOT persistent, so `seed-claude.sh` symlinks the whole `~/.ssh` dir to
  `~/.claude/ssh` on every boot. Make a passphrase-free key (so no ssh-agent is
  needed), register it with GitHub, and point ssh at it:
  ```sh
  mkdir -p ~/.claude/ssh && chmod 700 ~/.claude/ssh
  ssh-keygen -t ed25519 -C "claude-code container" -f ~/.claude/ssh/id_ed25519 -N ""
  gh auth refresh -h github.com -s admin:public_key   # one-time: grant key scope
  gh ssh-key add ~/.claude/ssh/id_ed25519.pub --title "claude-code container"
  cat > ~/.claude/ssh/config <<'EOF'
  Host github.com
    IdentityFile ~/.claude/ssh/id_ed25519
    IdentitiesOnly yes
  EOF
  chmod 600 ~/.claude/ssh/config
  ssh -T git@github.com   # expect: "Hi <user>! You've successfully authenticated"
  ```
  This is a one-time setup. Because `~/.ssh` is a directory symlink into
  `~/.claude`, the key, `config`, AND learned `known_hosts` fingerprints all
  survive rebuilds — git-over-SSH works immediately after a rebuild with no manual
  relinking and no re-accepting host keys. The `gh auth refresh` device flow prints
  a code — open the URL on your host to approve (firewall allows github.com).

## 8. Updating Claude Code
Installed via the native installer; auto-updates at container start (from the
allowlisted `downloads.claude.ai`). Manual: `claude update`. Health check:
`claude doctor`. If an update times out, see §2 (firewall).

## 9. Database (Postgres 18 + pgvector)
A shared Postgres server with the `vector` extension runs as a sidecar
(`claude-db`). Opt-in: start it with `make db-up` (off by default).
- Reach it from here as host **`db`**, port **5432**. Credentials are already in
  the environment, so `psql` / `pg_dump` / client libraries auto-connect:
  `PGHOST=db`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`, and `$DATABASE_URL`
  (`postgresql://claude:<pw>@db:5432/claude`). Never hardcode the password --
  read `$DATABASE_URL` or the `PG*` vars.
- Quick check: `psql -c '\l'` or `psql "$DATABASE_URL" -c 'select version();'`.
- **One server, many databases.** Per project, give it its own DB rather than a
  new container: `make db-create DB=myproject`, then `psql -d myproject` or
  `DATABASE_URL=postgresql://$PGUSER:$PGPASSWORD@db:5432/myproject`.
- **pgvector is enabled by default** — `vector` is installed in `template1`, so
  the default `claude` DB and EVERY new database (incl. bare `createdb`) already
  have it. No `CREATE EXTENSION` needed.
- Data persists in the `claude-pgdata` volume (survives rebuilds; `make nuke` /
  `make db-reset` destroy it). Back up with `make db-dump` -> ./db-backups (host).
- If `db` won't resolve/connect, the sidecar likely isn't running: `make db-up`.

## 10. Pointers
- Firewall: `/usr/local/bin/init-firewall.sh`; extras
  `/etc/claude-firewall/extra-allowlist.txt`.
- Shell: `~/.zshrc`, aliases `~/.config/zsh/aliases.zsh`, prompt
  `~/.config/starship.toml`.
- Live inventory: `~/.claude/ENVIRONMENT.md` (regenerated each boot).
