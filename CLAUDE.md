# claude-sandbox

Defines a modernized, security-sandboxed dev container that serves as a
self-contained home for Claude Code. Everything lives in `.devcontainer/`.

## What this repo is (and isn't)
- It is **container definition + config**, not an application. There is no app to
  run here on the host; the deliverable is the image and its startup behavior.
- Target runtime: Docker Desktop on **macOS/arm64** (Apple Silicon) OR Docker on
  **Windows WSL2/amd64** (Intel). Builds native to the host arch — no `platform:`
  pin (one would force slow emulation). Only arm64/amd64 are wired up;
  `install-tools.sh` errors on anything else.
- **Cross-platform invariants:** scripts must stay LF (enforced by
  `.gitattributes` + a defensive `sed 's/\r$//'` in the Dockerfile) or CRLF from a
  Windows checkout breaks the entrypoint with `bad interpreter: ...^M`. The
  firewall needs the Docker **WSL2 backend** on Windows (NET_ADMIN + iptables/ipset
  kernel support); the legacy Hyper-V backend won't load the rules.

## Build & run
```bash
docker compose -f .devcontainer/compose.yaml up -d --build   # or: make up
docker exec -it claude-code zsh -l                            # or: make shell
```
Compose project (group) = `claude`; container = `claude-code`.

## How startup works (the non-obvious part)
`ENTRYPOINT` = `entrypoint.sh`, which runs **in order**: (1) `sudo init-firewall.sh`,
(2) `seed-claude.sh`, (3) `claude update`, then execs the compose `command`
(`sleep infinity`). Ordering is load-bearing — the firewall must be up before the
auto-update can reach `downloads.claude.ai`. The VS Code path re-runs the firewall
+ update via `devcontainer.json` `postStartCommand` as an idempotent safety net.

## Invariants — break these and the container breaks
- **User is `claude`** (uid 1000, renamed from the base image's `node`). The name
  must match across Dockerfile `USER`, compose `user:`, devcontainer `remoteUser`,
  and `$HOME`/`$CLAUDE_CONFIG_DIR`.
- **Volume-shadowing rule:** anything baked into the image at a path that a named
  volume mounts over is hidden on first run. Baked files therefore live OUTSIDE
  volume paths — seed CLAUDE.md at `/usr/local/share/claude-seed/`, dotfiles at
  `/home/claude` (only `~/.claude`, `~/.local/share/pnpm` are volumes), Playwright
  browsers at `/usr/local/share/ms-playwright` (NOT the default `~/.cache`).
- **`~/.ssh` is a *directory* symlink to `~/.claude/ssh`, not per-file.**
  `seed-claude.sh` links the whole dir so the key, `config`, and `known_hosts` all
  persist in the volume. Don't "simplify" it to per-file symlinks (`~/.ssh/config`,
  `~/.ssh/known_hosts`): OpenSSH's `UpdateHostKeys` (default `yes`) and
  `ssh-keygen -R` rewrite `known_hosts` via temp-file + atomic rename, which
  replaces a per-file symlink with a real file in the ephemeral `~/.ssh` and
  silently reverts to non-persistence.
- **Build-time vs runtime network:** all installs happen at build time (no
  firewall). The firewall's allowlist only governs RUNTIME fetches — add a host to
  the allowlist only if it's needed *after* the container is up.
- **Firewall resolver is non-fatal per-domain** on purpose (e.g.
  `statsig.anthropic.com` has no public A record). Don't reintroduce a hard
  `exit 1` on resolution failure.
- **Firewall degrades, never bricks.** A preflight (`firewall_supported`) probes
  for iptables/ipset and, if absent (some WSL2 kernels), prints `FIREWALL
  DEGRADED` and `exit 0` with egress OPEN — so the container still boots. Keep
  that path `exit 0`; making a missing-kernel-feature fatal breaks WSL2 hosts.
- **Firewall resets default policies to ACCEPT before reconfiguring**, then
  clamps `OUTPUT` back to DROP at the end. This is load-bearing: `iptables -F`
  flushes rules but NOT the policy, so without the reset a *re-run* inherits the
  prior `OUTPUT DROP` and blocks its own `api.github.com/meta` bootstrap fetch
  (DNS resolves, `:443` times out → no GitHub ranges load). Don't remove the
  `iptables -P ... ACCEPT` block. The upstream Anthropic script has this bug.
- **`api.github.com/meta` ranges don't cover all of GitHub.** `github.com`
  (OAuth device-flow + git-over-HTTPS) and release-asset hosts
  (`objects.githubusercontent.com`, `codeload.github.com`) are pinned explicitly
  in `init-firewall.sh` — they're NOT in meta. Don't delete them as "redundant";
  doing so breaks `gh auth refresh` (`no route to host`) and `uv python install`.
- **AWS egress uses the published CIDR feed, not apex hostnames.** AWS endpoints
  are wildcard / per-region / CloudFront-fronted, so an `extra-allowlist.txt`
  *hostname* line can't reach them (a bare `amazonaws.com` has no useful A record;
  the few that resolve are CloudFront and go stale). Instead, an `@aws-ip-ranges`
  directive in `extra-allowlist.txt` makes `init-firewall.sh` fetch
  `ip-ranges.amazonaws.com/ip-ranges.json` (the AWS analog of GitHub's `/meta`)
  and load the `AMAZON` service prefixes (~1750 CIDRs) — covering `aws sso login`
  + the CLI (oidc/portal.sso/sts/s3/awsapps). Optional region args narrow the set
  (`@aws-ip-ranges us-east-1`); `GLOBAL`/CloudFront prefixes are always kept so
  narrowing can't break login. Don't re-add apex AWS hostnames — they're noise.
- **Editing a single-file bind mount (`extra-allowlist.txt`) needs a container
  *restart*, not just a firewall re-run.** The allowlist is bind-mounted as a lone
  file; on Docker Desktop macOS the mount is inode-pinned, so when an editor
  replaces the file (write-temp + rename → new inode) the container keeps serving
  the STALE inode. `docker exec … init-firewall.sh` then re-reads the old content.
  `docker restart claude-code` re-binds the mount to the current host file (and
  re-runs the entrypoint firewall). Symptom: host edits to the allowlist appear to
  have no effect even after re-running the firewall. (`make rebuild` also works —
  it bakes the file via the Dockerfile `COPY`.)
- **`extra-allowlist.txt` is gitignored/personal; the tracked file is
  `extra-allowlist.txt.example`.** A host preflight (`gen-allowlist.sh`, run by
  `make up`/`rebuild` and `devcontainer.json`'s `initializeCommand`, mirroring
  `gen-env.sh`/`.env`) seeds the real file from the template if missing. This is
  load-bearing, not cosmetic: the Dockerfile still `COPY`s `extra-allowlist.txt`
  and compose bind-mounts it, and a *missing* bind-mount source makes Docker create
  an empty directory there (→ `init-firewall.sh` reads a dir and breaks). Don't
  re-track `extra-allowlist.txt` or point the `COPY`/mount at the `.example`.
- **`FIREWALL_MODE` must be passed explicitly on the `sudo` line.** sudoers has
  `env_reset` and no `env_keep` for it, so a bare `sudo init-firewall.sh` would
  never see `FIREWALL_MODE` from compose and always run the script's `:-strict`
  default. Both call sites therefore use `sudo FIREWALL_MODE="${FIREWALL_MODE:-strict}"
  /usr/local/bin/init-firewall.sh` (an explicit `VAR=val` assignment survives
  `env_reset`) — `entrypoint.sh` and `devcontainer.json`'s `postStartCommand`.
  Don't drop the assignment back to a bare `sudo …`; that silently re-breaks the
  `permissive`/`dev` switch.
- **`docker cp`-ing a script into the running container drops its exec bit**
  (`sudo: …: command not found`). Source scripts are kept `+x` in git, but
  `docker cp` applies the host file mode and the Dockerfile's `chmod +x` only
  runs at build time — so after a cp, `docker exec -u root claude-code chmod +x
  <path>`. Or just `make rebuild` to bake the change in properly.
- **`uv python install` needs `--default`.** Without it, only a versioned shim
  (`python3.14`) is created and bare `python3` falls through to Debian's
  `/usr/bin/python3` (3.11) — the prompt/tools silently use the wrong interpreter.
  The `--default --preview-features python-install-default` form adds generic
  `python`/`python3` shims to `~/.local/bin` (first on PATH); don't drop it.
- **DB password applies only on first init of `claude-pgdata`.** The generated
  `.devcontainer/.env` (gitignored; `make env`) is baked into the data volume
  when Postgres first initializes — changing `.env` later does NOT re-key the
  running DB. Use `make db-reset` (destroys data) to apply a new password. The
  db sidecar is opt-in via the `db` compose profile (`make db-up`), and the
  pg18 *client* in the image must match the server major (older `pg_dump` refuses
  a newer server) — that's why the Dockerfile pulls `postgresql-client-18` from
  PGDG, not Debian's 15.
- **`.env` is read at container *create* time, not start.** compose's `env_file`
  injects `PG*`/`DATABASE_URL` only when a container is first created, so `.env`
  must exist *before* `claude-code` is created. The `make up`/`db-up` targets
  guarantee this (`up: env`), but VS Code "Reopen in Container" and a raw `docker
  compose up` don't — so `devcontainer.json`'s `initializeCommand` runs
  `gen-env.sh` on the host to close that gap. Symptom of a container born too
  early: empty `DATABASE_URL` inside `claude-code` (psql then falls back to the
  local socket and fails). Fix is `--force-recreate` (a plain `restart` re-reads
  nothing). The `.env` lives on the host only — the in-container `/workspace` is an
  isolated volume, so a missing `.env` *there* is normal, not the cause.
- **Firewall allows the real container subnet, not a guessed /24.** The compose
  net is a /16; `init-firewall.sh` reads the actual interface CIDR so sidecars
  (the db) stay reachable even if Docker assigns an IP outside `172.x.0.0/24`.
  Don't revert it to the `sed`-derived /24 — that silently breaks `db` egress.
- **Two load-bearing `db` service settings** (both have inline comments — don't
  "simplify" them away): `PGDATA=/var/lib/postgresql/data/pgdata` (a subdir — the
  pg18 image refuses to init at the volume mount root) and `PGHOST: ""` (the
  shared `.env` injects `PGHOST=db` client vars into the *server* container too,
  which would point its healthcheck at itself over TCP).

## File map
- `Dockerfile` — base + all build-time installs; `install-tools.sh` does the
  non-apt CLI toolbelt (cargo-binstall for Rust tools, direct download for
  yq/lazygit).
- `compose.yaml` / `devcontainer.json` — same container, two entry paths.
- `init-firewall.sh` — layered default-deny egress (`FIREWALL_MODE`,
  `config/extra-allowlist.txt`).
- `entrypoint.sh` / `seed-claude.sh` — startup orchestration + `~/.claude` seeding.
- `home/` — baked dotfiles. `seed/CLAUDE.md` — the in-container orientation doc.
- DB sidecar: `gen-env.sh` (generates the gitignored `.env` secret; `.env.example`
  is the template), `db-init/` (initdb scripts — pgvector in `template1`).

## Editing notes
- These are shell/Docker/JSONC files; the org Python/TS style guides don't apply,
  but keep the firewall scripts `set -euo pipefail` and resolver failures
  non-fatal.
- `devcontainer.json` is JSONC (comments allowed) — don't validate it with strict
  `jq`.
