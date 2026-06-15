# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.1] - 2026-06-15

### Added

- **Java runtime** — Eclipse Temurin **OpenJDK 11.0.31+11**, baked into the image for
  JVM workloads (e.g. the IBKR Client Portal Gateway). Pinned to 11 (not 17+) on
  purpose — a bundled netty reflectively accesses `java.nio.DirectByteBuffer`, fatal
  on 17+. Fetched from Adoptium's GitHub releases with a per-arch SHA-256 gate, in
  line with the project's pinned/integrity-verified build convention. `make smoke`
  now asserts the `java` / `JAVA_HOME` wiring, and the seeded `ENVIRONMENT.md` lists
  the JVM.

### Changed

- Repository renamed to **claude-devcontainer**; in-repo references and the README CI
  badge updated to the new path.

## [0.2.0] - 2026-06-14

A security/quality hardening pass driven by a full audit (summarized in
`docs/findings/REMEDIATION.md`), plus the project's first CI pipeline. Run
`make rebuild` to pick up the build-time and firewall changes on an existing
container.

### Added

- **Continuous integration** (`.github/workflows/ci.yaml`): shellcheck, hadolint,
  and yamllint static gates plus a `smoke` job that builds the image, boots it, and
  asserts the wiring (Claude CLI, the uv 3.14 `python3` shim, the toolbelt, the seed
  doc). `make lint` / `make smoke` run the same checks locally; `main` is now
  branch-protected on these checks, and the README carries a CI status badge.
- **Boot-event observability** (`log-event.sh`): the entrypoint, firewall, seed, and
  cron phases emit a JSONL lifecycle trail under `~/.claude`, correlated by a per-boot
  `BOOT_ID`. `make boot-check` asserts the expected events fired in order.
- **IPv6 egress filtering**: `ip6tables` is configured fail-closed in strict mode
  (with `net.ipv6.conf.*.disable_ipv6` sysctls as a backstop), so a dual-stack host no
  longer bypasses the allowlist over IPv6.
- **Container healthcheck** asserting the effective firewall mode, the Claude CLI, the
  cron daemon, and the seeded `ENVIRONMENT.md`.
- **`.dockerignore`** (default-deny) so the generated `.env` (the Postgres password)
  never enters the build context.

### Changed

- **Firewall fails closed.** The window where egress is opened to fetch the GitHub/AWS
  IP feeds is now guarded by an `EXIT` trap that re-clamps `OUTPUT`/`INPUT` to `DROP` on
  any mid-apply abort — previously an abort there could leave egress wide open.
  Concurrent firewall runs serialize on a `flock`.
- **Reproducible, tamper-evident build.** The base image is digest-pinned and every
  fetched tool (yq, lazygit, AWS CLI, cargo-binstall, pnpm, the npm globals, uv) is
  version-pinned and verified by SHA-256 or GPG signature before use; the two
  third-party apt keys (GitHub CLI, PGDG) are fingerprint-verified. A `SHELL [… -o
  pipefail …]` directive makes `curl | sh` build layers fail closed.
- **Lifecycle Make targets are db-profile-aware.** `stop` / `down` / `nuke` now tear
  down the opt-in `db` sidecar and its volumes, so `make nuke` actually destroys the
  database data as documented.
- **`claude update` at boot is time-bounded** (and remains non-fatal), so a slow
  network can't hang startup.
- Dropped the `NET_RAW` capability — the firewall needs only `NET_ADMIN`.

### Fixed

- **DNS / SSH exfiltration channels closed.** Strict mode no longer allows blanket
  `udp/53` or `tcp/22` to any host: DNS is scoped to the resolver(s) in
  `/etc/resolv.conf`, and git-over-SSH reaches GitHub via the `allowed-domains` ipset.
- **`@aws-ip-ranges <region>` narrowing** loaded zero CIDRs (a jq bug) and could break
  AWS login; it now filters correctly and always retains the GLOBAL/CloudFront prefixes.
- **Cron jobs couldn't reach Postgres** — `cron.env` now includes the `PG*` /
  `DATABASE_URL` client vars.
- **VS Code `postStartCommand` swallowed firewall failures** (it always exited 0); a
  firewall error now propagates while update/cron stay non-fatal.
- `make db-dump` writes atomically (temp file + rename); `gen-env.sh` re-secures `.env`
  to `0600`; the zsh `compinit` fast-path guard (which was always-true) is fixed.

### Documentation

- Security/quality **audit** under `docs/findings/`, with a remediation summary
  (`docs/findings/REMEDIATION.md`).
- Split `CLAUDE.md` into a lean root plus `.devcontainer/CLAUDE.md` (per-script
  invariants), reconciled with the hardening above.
- README: CI badge, `--force-recreate` for the permissive-mode switch, and a DB
  quickstart precondition.

## [0.1.5] - 2026-06-09

### Added

- Scheduled agents via **cron**: the `cron` daemon is installed and started at
  boot, and the crontab is a real file in the persistent `~/.claude` volume
  (`~/.claude/cron/crontab`) re-installed into the live spool every boot by
  `init-cron.sh`. Symlinking the spool into a volume can't work — Debian's Vixie
  cron silently ignores symlinked / wrong-perm crontabs — so the file is the
  source of truth and survives rebuilds. Jobs run with a reconstructed
  environment (`cron.env` regenerated each boot + `SHELL=/bin/bash` + `BASH_ENV`),
  so `claude -p` runs non-interactively with the persisted `~/.claude` auth.
  Helpers: `crontab-edit` / `crontab-reload`; `make cron-reload` / `make cron-log`.

### Fixed

- `/usr/local/share/npm-global/bin` appeared twice in `PATH` (section 4 prepended
  it for the build, then the final `ENV` prepended it again). The runtime `PATH`
  is now spelled out in full to match `entrypoint.sh`, so it's single-entry and no
  longer leaks the duplicate into snapshots of the live env (e.g. `cron.env`).

### Documentation

- New "Scheduled agents (cron)" sections in `README.md` and the in-container
  `seed/CLAUDE.md`; `CLAUDE.md` documents the cron invariants (file-not-symlink
  source of truth, the stripped-env reconstruction via `cron.env` + `BASH_ENV`,
  and the `pgrep`-guarded daemon start).

## [0.1.4] - 2026-06-03

### Changed

- Default container timezone is now **America/New_York** (was
  `America/Los_Angeles`). Override per-host with the `TZ` env var, which
  `compose.yaml` threads into both the build arg and the runtime environment.

### Fixed

- Split-brain timezone: the base image set `ENV TZ` (honored by glibc CLI tools
  like `date`) but never configured `/etc/localtime`, so anything reading the
  system clock files — e.g. Python's `datetime` — silently fell back to
  `Etc/UTC`. The Dockerfile now installs `tzdata` and pins `/etc/localtime` +
  `/etc/timezone` from `$TZ` at build time so the env var and system files agree.
  A zone switch requires a rebuild (the zone is baked into `/etc/localtime`).

### Documentation

- README gains a "Timezone" section (override via `TZ`, rebuild caveat).
  `CLAUDE.md` documents the invariant: `TZ` lives in three places that must agree,
  and the clock is the host kernel's — no in-container NTP.

## [0.1.3] - 2026-06-02

### Changed

- The firewall allowlist is now templated: the repo ships an anonymized
  `config/extra-allowlist.txt.example`, and the real `config/extra-allowlist.txt`
  is **gitignored** (it may hold LAN IPs / private hosts). A host preflight
  (`gen-allowlist.sh`, run by `make up`/`rebuild` and `devcontainer.json`'s
  `initializeCommand`) seeds the real file from the template if missing — required
  because a missing bind-mount source would make Docker create an empty directory
  there and break `init-firewall.sh`. The template keeps `@aws-ip-ranges` active by
  default (the image ships the AWS CLI).

### Security

- Removed personal data from the tracked allowlist (a LAN IP and personal
  financial-data hosts) ahead of making the repo public.

## [0.1.2] - 2026-06-02

### Changed

- SSH persistence now covers `known_hosts` / `known_hosts.old`: `seed-claude.sh`
  symlinks the whole `~/.ssh` dir to the persistent `~/.claude/ssh` volume (instead
  of just the `config` file), so learned host fingerprints survive rebuilds and no
  longer need re-accepting. A directory symlink is required — OpenSSH rewrites
  `known_hosts` via temp-file + atomic rename, which would clobber a per-file
  symlink.

## [0.1.1] - 2026-06-01

### Added

- Firewall allowlist now accepts a bare **IPv4 address or CIDR** (e.g. a LAN host)
  on its own line in `extra-allowlist.txt`, added straight to the ipset. Hostnames
  are still resolved at apply time.
- Financial-data egress hosts (Robinhood, Yahoo Finance, Finviz, Zacks,
  TradingView) to the extra-allowlist.

### Documentation

- README "Network posture" now documents literal IP/CIDR allowlist entries and the
  Docker Desktop macOS inode-pin caveat (edit + re-run reads stale content; restart
  to re-bind the mount).

## [0.1.0] - 2026-06-01

Initial release — a modernized, security-sandboxed dev container that serves as a
self-contained home for Claude Code, derived from Anthropic's official
`.devcontainer`.

### Added

- Multi-arch image (macOS/arm64 + Windows WSL2/amd64), built native to the host —
  no emulation. Node 24 / Debian bookworm base; user `claude` (passwordless sudo),
  zsh + starship.
- Default-deny egress firewall (`init-firewall.sh`) with an expanded allowlist, a
  host-editable `extra-allowlist.txt`, and a `FIREWALL_MODE=permissive` escape
  hatch. Non-fatal per-domain resolver; degrades (rather than bricks) on kernels
  that lack iptables/ipset.
- AWS egress via the published `ip-ranges.json` feed (`@aws-ip-ranges` directive),
  AWS CLI v2 baked into the image, and `~/.aws` / `~/.ssh` persisted across
  rebuilds.
- Language toolchains: TypeScript / pnpm / tsx, Python 3.14 via `uv` + `ruff` +
  `pyright`, Playwright + Chromium baked in. CLI toolbelt (ripgrep, fd, bat, eza,
  zoxide, fzf, jq, yq, delta, gh, lazygit, …).
- Opt-in shared Postgres 18 + pgvector sidecar (`db` compose profile) with a
  generated, injected `.env` secret and pgvector enabled in `template1`.
- `Makefile` shortcuts (`up`, `shell`, `rebuild`, `firewall`, `cp-skill`, the
  `db-*` targets, …) and a VS Code "Reopen in Container" path sharing the same
  compose file.
- MIT license for this repo's original work, `SECURITY.md`, and upstream
  attribution to Anthropic's devcontainer.

[Unreleased]: https://github.com/ChrisSc/claude-devcontainer/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/ChrisSc/claude-devcontainer/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/ChrisSc/claude-devcontainer/compare/v0.1.5...v0.2.0
[0.1.5]: https://github.com/ChrisSc/claude-devcontainer/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/ChrisSc/claude-devcontainer/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/ChrisSc/claude-devcontainer/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/ChrisSc/claude-devcontainer/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/ChrisSc/claude-devcontainer/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/ChrisSc/claude-devcontainer/releases/tag/v0.1.0
