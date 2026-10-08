# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **pgAdmin 4 web UI for the db sidecar** (`claude-pgadmin`). It sits on the same
  compose network and reaches the server as `db:5432`, and it's published to the host
  loopback only, at <http://localhost:5050>. It's in the existing `db` profile, so
  the profile-aware `stop`/`down`/`nuke` targets cover it, but it starts only on
  request: `make pgadmin-up`, `pgadmin-down`, `pgadmin-reset` (`make db-up` still
  starts the db alone).
  - **Pre-registered, password-free connection.** The `claude-db` server
    (`servers.json`) and a pgpass are inline compose `configs`, filled in from
    `.env` when the container is created. The entrypoint copies the pgpass into
    pgAdmin's per-user storage, so the server connects without asking for the DB
    password. Nothing new is tracked. The pgpass is mounted `0400` and owned by
    pgAdmin's user, not left world-readable.
  - **Separate login secret.** `gen-env.sh` now also generates
    `.devcontainer/pgadmin.env` (gitignored, `0600`, also excluded from the build
    context) holding `PGADMIN_DEFAULT_PASSWORD`, with the fixed login
    `claude@example.com`. It's separate from `.env` for two reasons: the shared file
    would push the pgAdmin password into `claude-code` and the db, and an existing
    `.env` would have needed rewriting. Existing installs get the new file on the
    next `make env`/`up`.
  - **First start only, like the DB password.** The login, the server import and
    the pgpass apply only on first init of the `claude-pgadmin` volume. After
    rotating the DB password or editing `pgadmin.env`, run `make pgadmin-reset`.
  - **Hardened.** The image is `dpage/pgadmin4:9.18.0` pinned by index digest
    (upstream re-pushes tags; `9.17.0` currently points at the 9.18 image). The
    container runs with `cap_drop: [ALL]` and `no-new-privileges`, listens on 8080
    (dropping all capabilities rules out port 80), and has the pgadmin.org update
    check and the bundled postfix disabled. The healthcheck hits `/misc/ping`.

- **Agent Toolkit for AWS, wired up by default** — Claude now boots with live AWS
  tools and AWS domain guidance, no manual setup. Two halves, both handled by the new
  `init-aws-toolkit.sh` (entrypoint step 4, after `claude update`, before cron):
  - **AWS MCP Server** — registers the `aws-mcp` stdio server pointing at the new
    build-pinned `mcp-proxy-for-aws` (`ARG MCP_PROXY_FOR_AWS_VER=1.6.4`, installed via
    `uv tool install` beside `ruff`), which SigV4-signs calls to AWS's hosted endpoint
    `https://aws-mcp.<region>.api.aws/mcp`. Pinning at build time is deliberate: the
    upstream docs suggest `uvx mcp-proxy-for-aws@X`, which would resolve from PyPI
    every time the server starts — a supply-chain hole and a startup-latency hit.
  - **Skills** — the 23-skill `aws-core` catalog set, pinned by version in the new
    `seed/aws-skills.txt` manifest and installed to `~/.claude/skills` via the
    `aws agent-toolkit` command group (already present in the pinned CLI 2.36.11,
    which satisfies the toolkit's `>= 2.35.0` requirement — no CLI bump needed).
  - **Credentials gate the whole server, not just its API tools.** The proxy signs
    every request including `initialize`, so without resolvable credentials `aws-mcp`
    fails to connect and Claude Code reports an opaque `-32602: Invalid request
    parameters`. (Upstream docs say credential-free doc/skill discovery still works
    over MCP; measured against 1.6.4 it does not.) The boot step therefore probes with
    `aws sts get-caller-identity`, logs `aws.credentials.ok`/`.absent`, and prints a
    "run `aws sso login`" hint — an absent credential is a normal, user-fixable state,
    so it is reported, not treated as a degraded boot. Skills work regardless.
  - **Multi-account by design (`AWS_MCP_PROFILES`).** The proxy's `--profile` flag is
    variadic, so one server spans an AWS Organization: the first profile in the
    space-separated list is the default identity and the rest are selectable **per
    tool call** via its `aws_profile` parameter, with no restart between accounts.
    Empty by default (profile names are host-specific) — set it per host in
    `.devcontainer/.env`, which `gen-env.sh` never rewrites once generated; see
    `.env.example`. The credential probe targets the *default* profile rather than the
    ambient chain, since only the first one governs whether the handshake succeeds.
  - **⚠ Writes are enabled by default** (`AWS_MCP_READ_ONLY=0`). The MCP tools act with
    the full IAM permissions of the selected profile and can create, modify, and
    **delete** real resources — in any account in `AWS_MCP_PROFILES`, not just the
    default. Order that list least-privileged-first, because position 1 is what an
    unqualified call uses. `AWS_MCP_READ_ONLY=1` passes `--read-only` and restores
    describe-only; `AWS_MCP_REGION` picks the region (default `us-east-1`). The
    in-container guidance tells Claude to confirm the target account before mutating.
  - **No firewall change was required.** Both `aws-mcp.<region>.api.aws` and the
    `agent-toolkit.<region>.api.aws` skill catalog resolve into CloudFront prefixes
    tagged `AMAZON`/region `GLOBAL`, which the existing `@aws-ip-ranges` directive
    always keeps — verified against the live `ip-ranges.json` feed and in a strict-mode
    boot, not assumed.
  - The MCP entry is **re-registered on every boot** rather than seeded once: `~/.claude`
    is a persistent volume, so a copy-if-missing entry would freeze the first boot's
    proxy version and flags forever. Skills are gated on the SHA-256 of the manifest
    (stamped at `~/.claude/aws-toolkit/.skills-stamp`), so steady-state boots do no network I/O
    and a deliberately removed skill stays removed. Every failure path is non-fatal and
    still emits `aws.toolkit.ready`, which `make boot-check` now requires along with
    `aws.mcp.registered`.

### Changed

- **AWS CLI bumped `2.35.4` → `2.36.11`** (`install-tools.sh` `AWS_CLI_VER`). Routine
  upstream bump — no paired checksum to update, because the supply-chain gate for this
  tool pins AWS's public-key *fingerprint* (`AWS_CLI_PGP_FPR`), which is stable across
  releases, rather than a per-release digest. Both arch bundles
  (`awscli-exe-linux-{x86_64,aarch64}-2.36.11.zip`) and their detached `.sig` files were
  confirmed published at the versioned path before the pin moved. Note that the CLI
  lives at `/usr/local/aws-cli` (not a named volume), so picking this up requires a
  container **recreate**, not a restart; credentials are unaffected either way since
  `AWS_CONFIG_FILE`/`AWS_SHARED_CREDENTIALS_FILE` point into the `claude-config` volume.

### Fixed

- **`aws sso login` did not survive a rebuild.** `AWS_CONFIG_FILE` /
  `AWS_SHARED_CREDENTIALS_FILE` relocate only `config` and `credentials` into the
  `claude-config` volume — but the SSO/OIDC **token cache path is not configurable**, so
  the CLI kept writing `~/.aws/cli/cache/session.db` (and `~/.aws/sso/cache/`) to the
  container layer, where `make rebuild` destroys it. Config persisted, tokens didn't, so
  every profile needed a fresh login after each rebuild. `seed-claude.sh` now points
  `~/.aws` at `~/.claude/aws` as a **directory** symlink — the same fix, and the same
  per-file-symlink trap (temp-file + atomic rename), as `~/.ssh`. An existing `~/.aws` is
  migrated into the volume with `cp -an` before the swap, so a live token cache is
  preserved rather than dropped. `make boot-check` now requires the new
  `seed.aws.linked` event, and the toolkit's skills stamp moved to
  `~/.claude/aws-toolkit/` so its bookkeeping never surfaces inside the user's AWS dir.
- **Documented that SSO login needs `--use-device-code` in a container.** `aws sso
  login` defaults to the Authorization Code flow, which opens a browser and waits on a
  `127.0.0.1` redirect listener — bound *inside* the container, so a host browser can
  never reach it and the login hangs. The Device Code grant prints a URL + code to open
  on the host instead. The boot-time credential hint and the in-container guidance now
  show `aws sso login --profile <name> --use-device-code`, with the reason.
- **`make smoke` / CI asserted against a still-booting container.** Both waited for
  `~/.claude/ENVIRONMENT.md`, which the seed step writes at **step 2 of 6** — before
  `claude update`, the AWS toolkit, and cron. Every assertion after that wait was
  racing the rest of the boot; it only ever passed because the checks happened to
  target step-1/2 artifacts. Both now wait for `pgrep -x cron`, the last step before
  `exec` (and the same liveness proxy the compose healthcheck uses). Surfaced by the
  new AWS assertion, which runs later in the pipeline and so lost the race reliably.
- **`jq -e 'select(...)'` is not a membership test.** With `-e`, jq's exit status
  reflects only the **last input line**, so the boot-journal probes passed purely
  because `entrypoint.ready` happens to be the journal's final event — the same idiom
  returns exit 4 for any event that isn't last. Replaced with
  `jq -se 'any(.[]; .event=="…")'` in the `boot-check` wait loop and the new smoke/CI
  assertions.

## [0.2.3] - 2026-06-15

### Fixed

- **Gateway unreachable at `localhost:5000` on macOS** — the v0.2.2 publish used host
  port 5000, which macOS reserves for the AirPlay Receiver (Control Center binds
  `*:5000`, including IPv6 `::1`). Because `localhost` resolves to `::1` first on
  macOS, the browser hit AirPlay instead of the IPv4-only Docker publish and never
  reached the gateway. Remap the host side to **5001** (`127.0.0.1:5001:5000`;
  container side stays 5000 to match the gateway's `listenPort`) → browse
  `https://localhost:5001`. Needs a container recreate to apply.

## [0.2.2] - 2026-06-15

### Added

- **Host access to the IBKR Client Portal Gateway** — publish the gateway's web UI
  (`clientportal.gw` binds `:5000` inside the container) to the host **loopback only**
  (`127.0.0.1:5000:5000`), matching the db sidecar's never-public posture. The egress
  firewall does not block this inbound path: the host connection arrives sourced from
  the Docker bridge gateway (`172.x.0.1`), which is inside `CONTAINER_CIDR`, so
  `init-firewall.sh`'s `INPUT` allow accepts it in every mode. Applying it needs a
  container recreate (`docker compose up -d` / `make rebuild`), and the gateway's own
  `root/conf.yaml` `ips.allow` must include `172.*` or it rejects the login at the app
  layer.

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

[Unreleased]: https://github.com/ChrisSc/claude-devcontainer/compare/v0.2.3...HEAD
[0.2.3]: https://github.com/ChrisSc/claude-devcontainer/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/ChrisSc/claude-devcontainer/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/ChrisSc/claude-devcontainer/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/ChrisSc/claude-devcontainer/compare/v0.1.5...v0.2.0
[0.1.5]: https://github.com/ChrisSc/claude-devcontainer/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/ChrisSc/claude-devcontainer/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/ChrisSc/claude-devcontainer/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/ChrisSc/claude-devcontainer/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/ChrisSc/claude-devcontainer/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/ChrisSc/claude-devcontainer/releases/tag/v0.1.0
