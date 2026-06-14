# claude-sandbox

A modernized, security-sandboxed dev container that is a self-contained home for
Claude Code. **Container definition + config, not an app** — the deliverable is the
image and its startup behavior; there's nothing to run on the host. Everything lives
in `.devcontainer/`.

## What this repo is (and isn't)
- Target runtime: any Docker host on **arm64 or amd64** — native **Linux**, Docker
  Desktop on **macOS**, or **Windows WSL2**. Support is gated on *arch*, not OS
  (everything runs in a Linux container; `install-tools.sh` errors on
  non-arm64/amd64). Builds native to the host arch — no `platform:` pin (would force
  slow emulation). Native Linux runs the firewall fully (iptables/ipset in-kernel);
  macOS/Windows add a Docker Desktop VM layer — the source of the inode-pinned
  bind-mount and WSL2-vs-Hyper-V firewall caveats.
- **Scripts must stay LF** (enforced by `.gitattributes` + a defensive
  `sed 's/\r$//'` in the Dockerfile); CRLF from a Windows checkout breaks the
  entrypoint with `bad interpreter: …^M`. The firewall needs Docker's **WSL2
  backend** on Windows (NET_ADMIN + iptables/ipset); the legacy Hyper-V backend
  won't load the rules.

## Build & run
```bash
docker compose -f .devcontainer/compose.yaml up -d --build   # or: make up
docker exec -it claude-code zsh -l                            # or: make shell
```
Compose project (group) = `claude`; container = `claude-code`. Makefile targets are
self-documented — each carries a trailing `## …` description.

## Startup order (load-bearing)
`ENTRYPOINT` = `entrypoint.sh`, in order: (1) `sudo init-firewall.sh`,
(2) `seed-claude.sh`, (3) `claude update` (bounded by `timeout`, non-fatal),
(4) `init-cron.sh`, then execs the compose `command` (`sleep infinity`). Ordering
matters — the firewall must be up before the auto-update reaches
`downloads.claude.ai` and before cron jobs fire. The VS Code path re-runs
firewall + update + cron via `devcontainer.json` `postStartCommand` as an
idempotent safety net.

## Cross-file invariants
- **User is `claude`** (uid 1000, renamed from the base image's `node`). The name
  must match across Dockerfile `USER`, compose `user:`, devcontainer `remoteUser`,
  and `$HOME`/`$CLAUDE_CONFIG_DIR`.
- **Volume-shadowing rule:** a file baked at a path a named volume mounts over is
  hidden on first run. Baked files live OUTSIDE volume paths — seed CLAUDE.md at
  `/usr/local/share/claude-seed/`, dotfiles at `/home/claude` (only `~/.claude`,
  `~/.local/share/pnpm` are volumes), Playwright browsers at
  `/usr/local/share/ms-playwright` (NOT the default `~/.cache`).
- **`~/.ssh` is a *directory* symlink to `~/.claude/ssh`, not per-file.**
  `seed-claude.sh` links the whole dir so key + `config` + `known_hosts` persist.
  Don't switch to per-file symlinks: OpenSSH's `UpdateHostKeys` / `ssh-keygen -R`
  rewrite `known_hosts` via temp-file + atomic rename, replacing a per-file symlink
  with a real file in the ephemeral `~/.ssh` and silently breaking persistence.

## Validation & workflow
- **Run `make lint` before committing** — it mirrors CI (shellcheck + hadolint +
  yamllint + `docker compose config`). `make smoke` builds+boots and asserts wiring;
  `make boot-check` asserts the boot event trail.
- **CI (`.github/workflows/ci.yaml`) gates every push/PR** with jobs `shellcheck`,
  `hadolint`, `yamllint`, `smoke`. Lint configs live at repo root (`.shellcheckrc`,
  `.hadolint.yaml`, `.yamllint`). Two deliberate suppressions you'll re-trip if you
  "clean them up": shellcheck skips the `home/` **zsh** dotfiles (`ignore_paths:
  home` — it has no zsh mode) and hadolint ignores **SC1091** (the
  `. /etc/os-release` PGDG line, a build-only file).
- **`main` is branch-protected**: required checks must pass, so land changes via PR,
  not direct push (the repo owner can override). The `remediate-findings` workflow
  merges on its *own* local validation, not GitHub Actions — under protection its
  batches now stay as open PRs until CI passes.

## Deep per-script invariants
Before editing any script in `.devcontainer/` (firewall, build/supply-chain, cron,
db, observability), read **`.devcontainer/CLAUDE.md`** — it holds the per-subsystem
errata (firewall fail-closed / IPv6 / DNS-scoping / SSH-via-ipset, pinning gates,
cron env, db lifecycle, boot-event trail).

## File map
- `.devcontainer/Dockerfile` + `install-tools.sh` — build-time installs (pinned +
  integrity-gated); `.dockerignore` keeps `.env` out of the build context.
- `compose.yaml` / `devcontainer.json` — same container, two entry paths.
- `init-firewall.sh` — layered default-deny egress (`FIREWALL_MODE`,
  `config/extra-allowlist.txt`).
- `entrypoint.sh` / `seed-claude.sh` — startup orchestration + `~/.claude` seeding;
  `log-event.sh` — boot-event JSONL trail.
- `init-cron.sh` + `crontab-edit` / `crontab-reload` — persisted crontab (don't
  shadow the real `crontab`); template `seed/crontab`.
- `home/` — baked zsh dotfiles. `seed/CLAUDE.md` — the **in-container** orientation
  doc (different audience: the Claude *using* the sandbox, not editing this repo).
- DB: `gen-env.sh` (generates the gitignored `.env`; `.env.example` is the
  template), `db-init/` (initdb scripts — pgvector in `template1`).
- Repo root: `Makefile`, `.github/workflows/ci.yaml`, the lint configs, `SECURITY.md`.

## Editing notes
- Shell / Docker / JSONC — the org Python/TS style guides don't apply. Keep firewall
  scripts `set -euo pipefail` with non-fatal resolvers. `devcontainer.json` is JSONC
  (comments allowed) — don't validate it with strict `jq`.
