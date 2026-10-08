# .devcontainer — per-script invariants (read before editing any script here)

Errata for the container scripts: break one and the container boots broken, often
silently. The root `CLAUDE.md` holds the overview, startup order, cross-file rules,
and the lint/CI workflow; this file is the deep detail for the files in this dir.
(Note: `seed/CLAUDE.md` is a *different* doc — it's baked into the image for the
Claude that *uses* the sandbox, not the one editing this repo.)

## Firewall (`init-firewall.sh`) — the security boundary
- **Fails CLOSED on abort.** The script opens `OUTPUT ACCEPT` early to fetch the
  GitHub/AWS CIDR feeds, so an `EXIT` trap (set right after the open) re-clamps
  `OUTPUT`/`INPUT` to `DROP` on ANY mid-script exit, cleared (`trap - EXIT`) only
  once the final ruleset is committed. Don't remove the trap or hoist `trap - EXIT`
  earlier — that reopens the fail-OPEN window (the upstream Anthropic script's bug).
- **Degrades, never bricks.** A preflight (`firewall_supported`) probes for
  iptables/ipset; if absent (some WSL2 kernels) it prints `FIREWALL DEGRADED` and
  `exit 0` with egress OPEN so the container still boots. Keep that path `exit 0`.
- **Resets policy to ACCEPT before reconfiguring, then clamps to DROP.** `iptables
  -F` flushes rules but NOT the policy; without the reset a re-run inherits the
  prior `OUTPUT DROP` and blocks its own `api.github.com/meta` bootstrap fetch.
  Keep the `iptables -P … ACCEPT` block.
- **IPv6 fails closed too.** `ip6tables_supported` gates `HAVE_IP6`; strict mode
  mirrors v4 with ip6tables `OUTPUT DROP` + REJECT, and `compose.yaml` sets
  `net.ipv6.conf.*.disable_ipv6=1` as a backstop. Keep both — without them a
  dual-stack host reaches every AAAA destination unfiltered.
- **DNS is scoped to the resolver; SSH rides the ipset — both deliberate.** strict
  mode allows udp+tcp/53 ONLY to the `/etc/resolv.conf` nameservers (127.0.0.11
  fallback) plus the embedded resolver's plain `# ExtServers:` upstreams, NOT
  any-destination. Those upstreams come from compose `dns:` (8.8.8.8/8.8.4.4) and
  Docker dials them from the *container* netns — drop that allow and strict mode
  SERVFAILs every lookup (`host(x)` upstreams are dialed host-side, need no rule).
  `dns:` itself is load-bearing: Docker Desktop's default forwarder goes through
  the host OS resolver, which caches upstream timeouts as NXDOMAIN — short-TTL
  `github.com` then fails ("Could not resolve host") while other hosts work.
  And there is NO blanket `--dport 22` rule —
  git-over-SSH reaches github.com because the OUTPUT match-set rule allows ALL
  ports to `allowed-domains` IPs. Don't "restore" a blanket udp/53 or tcp/22 allow
  as a perceived omission; those are exfil channels the hardening removed on purpose.
- **Resolver is non-fatal per-domain** (e.g. `statsig.anthropic.com` has no public
  A record). Don't reintroduce a hard `exit 1` on resolution failure.
- **Overlapping runs serialize on `flock 9` (`/run/claude-firewall.lock`)** so a
  boot apply and a `make firewall` / agent CDN refresh can't interleave a
  half-built ipset.
- **`api.github.com/meta` doesn't cover all of GitHub.** `github.com` (OAuth +
  git-over-HTTPS) and release-asset hosts (`objects.githubusercontent.com`,
  `codeload.github.com`) are pinned explicitly — NOT in meta. Deleting them breaks
  `gh auth refresh` and `uv python install`.
- **AWS egress uses the published CIDR feed, not apex hostnames.** An
  `@aws-ip-ranges [region…]` directive in `extra-allowlist.txt` makes the script
  fetch `ip-ranges.amazonaws.com/ip-ranges.json` and load the `AMAZON` prefixes
  (GLOBAL/CloudFront always kept, so a region narrow can't break login). A bare
  `amazonaws.com` line can't reach them — don't re-add apex AWS hosts.
- **`FIREWALL_MODE` must be an explicit `VAR=val` on the `sudo` line** (`sudo
  FIREWALL_MODE=… BOOT_ID=… init-firewall.sh`): sudoers `env_reset` strips the
  ambient var, so a bare `sudo init-firewall.sh` always runs the `:-strict` default.
  The script records the effective mode in `/etc/claude-firewall/mode`; a bare
  re-run defaults to that file so it won't clamp a permissive container back to
  strict. Keep the mode-file write/read.
- **Allows the real interface CIDR, not a guessed /24.** The compose net is a /16;
  the script reads the actual interface CIDR so the `db` sidecar stays reachable
  even outside `172.x.0.0/24`.
- **Allowlist is a single-file bind mount → host edits need `docker restart`, not
  just a firewall re-run.** On Docker Desktop macOS the mount is inode-pinned: an
  editor's write-temp+rename swaps the inode, so the container keeps serving the
  STALE file and `init-firewall.sh` re-reads old content. `docker restart
  claude-code` (or `make rebuild`) re-binds it.
- **`extra-allowlist.txt` is gitignored/personal; the tracked template is
  `extra-allowlist.txt.example`.** `gen-allowlist.sh` (host preflight) seeds the
  real file if missing; the Dockerfile also bakes the `.example` and
  `init-firewall.sh` falls back to it, so a fresh-clone `docker compose up --build`
  still has an allowlist. A *missing* bind-mount source makes Docker create an
  empty dir there (→ the script reads a dir and breaks). Don't re-track the real
  file or point the COPY/mount at the `.example`.

## Build / supply chain (`Dockerfile`, `install-tools.sh`, `.dockerignore`)
- **Build-time installs run with NO firewall** (it only governs runtime). The
  allowlist is irrelevant to the build — add a host only if needed *after* boot.
- **Everything external is PINNED + integrity-gated; bumps are deliberate.** Base
  image digest-pinned; yq/lazygit by `*_VER` + SHA-256, AWS CLI by GPG signature,
  cargo-binstall by release tag (not `main`), pnpm / npm-globals / uv via Dockerfile
  ARGs, zsh plugins by tag + asserted commit SHA; Temurin OpenJDK by release tag +
  per-arch SHA-256; `mcp-proxy-for-aws` by exact `==` ARG pin; the two third-party
  apt keys (GitHub CLI, PGDG)
  fingerprint-verified. Bump a version *and* its paired checksum together — a
  mismatch fails the build by design. Keep the `SHELL [… -o pipefail …]` line
  (DL4006 fix) so `curl | sh` layers stay fail-closed. Don't revert any to floating
  `latest`/`main`.
- **JDK is pinned to OpenJDK *11* on purpose — do NOT bump to 17+.** Section 5 bakes
  Eclipse Temurin 11 (for the IBKR `clientportal.gw` gateway) from Adoptium's GitHub
  releases. The gateway's bundled netty-4.1.15 reflectively accesses
  `java.nio.DirectByteBuffer`: a harmless warning on 11, a fatal
  `InaccessibleObjectException` on 17+ (Debian bookworm's only apt OpenJDK), which
  would force `--add-opens` flags in `run.sh`. `update-alternatives` puts java/javac
  in `/usr/bin` (already on PATH); only `JAVA_HOME` gets an `ENV` — leave the
  load-bearing final `PATH` untouched.
- **`.dockerignore` is default-deny** (ignore `*`, re-include only Dockerfile COPY
  sources) to keep the generated `.env` (Postgres password) out of the build
  context. Add a `!`-line for every new COPY source; don't widen to allow-all.
- **`uv python install` needs `--default --preview-features python-install-default`**
  — without it bare `python3` falls through to Debian's 3.11 instead of the uv 3.14
  shim in `~/.local/bin`.
- **Timezone is baked into `/etc/localtime` at build time.** `ARG TZ` sets the env
  var AND the `/etc/localtime` symlink + `/etc/timezone`; compose threads `${TZ}`
  into both the build arg and runtime env. A real zone switch needs a **rebuild**,
  not a `restart` (else `date` and Python `datetime` disagree). No in-container NTP
  — the clock is the host kernel's.
- **`docker cp` of a script into the running container drops its exec bit** (the
  Dockerfile `chmod +x` only runs at build). After a cp: `docker exec -u root …
  chmod +x <path>`, or `make rebuild`.

## Agent Toolkit for AWS (`init-aws-toolkit.sh`)
- **The MCP entry is REGENERATED every boot, not seeded once.** `~/.claude` is a
  persistent volume, so a copy-if-missing registration would freeze the *first*
  boot's proxy version and flags forever — bumping `MCP_PROXY_FOR_AWS_VER` or
  flipping `AWS_MCP_READ_ONLY` would rebuild the image and change nothing. The
  script does `claude mcp remove` then `claude mcp add --scope user`, making the
  container's declared config authoritative (the `ENVIRONMENT.md` model, not the
  `CLAUDE.md` one). Don't "fix" this into a seed-once check.
- **Never probe with `claude mcp list` / `get`.** Both health-check the server,
  which spawns `mcp-proxy-for-aws` and can hang when no AWS credentials exist.
  Idempotency comes from remove-then-add; the smoke/CI assertions read the
  `aws.mcp.registered` boot event instead.
- **`--region` is mandatory on every `aws agent-toolkit` call.** The skill catalog
  is *unauthenticated* (it installs fine with no credentials), but botocore still
  refuses to sign a request without a region, so a container whose
  `~/.claude/aws/config` is empty fails every skill install with `NoRegion`.
- **Skills are gated on the SHA-256 of `seed/aws-skills.txt`**, stamped at
  `~/.claude/aws/.skills-stamp`. A stamp hit short-circuits the whole step, so
  steady-state boots cost nothing and a skill the user deliberately removed stays
  removed. The stamp is written ONLY after a clean, complete pass — a partial or
  budget-truncated run retries next boot. Editing the manifest is what triggers a
  reconcile; removing a line does NOT uninstall (use `remove-skill`).
- **Both toolkit endpoints are already covered by `@aws-ip-ranges`.**
  `aws-mcp.<region>.api.aws` and `agent-toolkit.<region>.api.aws` resolve into
  CloudFront prefixes tagged `AMAZON`/region `GLOBAL`, which the loader always
  keeps even under a region narrow. Don't add apex AWS hosts to the allowlist.
- **No credentials ⇒ the MCP server fails to CONNECT, not just to call APIs.** The
  proxy SigV4-signs every request including `initialize`, and Claude Code renders
  that failure as an opaque `-32602: Invalid request parameters`. The script probes
  with `aws sts get-caller-identity` and logs `aws.credentials.ok` /
  `aws.credentials.absent` plus a "run `aws sso login`" hint, precisely because the
  raw symptom is undiagnosable. Absent credentials are normal and user-fixable, so
  the probe never sets `status=degraded`. (Upstream docs claim credential-free
  doc/skill-discovery still works over MCP — measured against 1.6.4, it does not.)
- **`--profile` is variadic and that is the point.** `AWS_MCP_PROFILES` is a
  space-separated list: the FIRST name is the server's default identity, the rest
  become selectable per tool call via the proxy's `aws_profile` parameter — one MCP
  server spanning an AWS Organization. The word-splitting in the script is
  deliberate (`# shellcheck disable=SC2086`) and guarded by an emptiness test so an
  unset value can never emit a bare `--profile`. The credential probe targets the
  *default* profile, not the ambient chain — with a list configured those are
  different identities and only the first governs the handshake.
- **WRITES ARE ON BY DEFAULT** (`AWS_MCP_READ_ONLY=0`). The tools act with the full
  IAM permissions of the selected profile and can create/modify/delete real
  resources in *any* account in `AWS_MCP_PROFILES` — not just the default. Order the
  list least-privileged-first, since position 1 is what an unqualified call uses.
  `AWS_MCP_READ_ONLY=1` restores `--read-only`. All three knobs are compose env vars
  (set per host in `.env`) and take effect on the next container *start*.
- **SSO login needs `--use-device-code` in this container.** `aws sso login` defaults
  to the Authorization Code flow, which opens a browser and waits on a `127.0.0.1`
  redirect listener — bound *inside* the container, so the host browser can never
  reach it and the login hangs. The Device Code grant prints a URL + code instead.
  Every doc/hint that shows an `aws sso login` invocation carries the flag; keep it.
- **`~/.aws` must stay a directory symlink into the volume** (`seed-claude.sh`).
  `AWS_CONFIG_FILE`/`AWS_SHARED_CREDENTIALS_FILE` relocate only `config` and
  `credentials`; the SSO/OIDC **token cache path is not configurable** — the CLI
  always writes `~/.aws/cli/cache/session.db` and `~/.aws/sso/cache/`. Left on the
  container layer those die with every rebuild, so config would survive but every
  profile would need a fresh `aws sso login`. Same per-file-symlink trap as `~/.ssh`:
  the CLI rewrites these caches via temp-file + atomic rename. Because `~/.aws` now
  *is* `~/.claude/aws`, the toolkit's own bookkeeping deliberately lives in
  `~/.claude/aws-toolkit/` instead, so it never shows up inside the user's AWS dir.
- Every failure path still emits `aws.toolkit.ready` and exits 0 — `make
  boot-check` requires that event unconditionally, so it must stay unconditional.

## Cron (`init-cron.sh`)
- **Crontab source of truth is `~/.claude/cron/crontab`, re-installed into the spool
  at boot — NOT symlinked.** Vixie cron silently ignores symlinked/wrong-perm
  crontabs, so the ssh dir-symlink trick doesn't work; `init-cron.sh` runs
  `crontab <file>` on a real file. Bare `crontab -e` hits the ephemeral spool and is
  lost on rebuild — use `crontab-edit`/`crontab-reload`.
- **Jobs run with a stripped env**, so the crontab sets `BASH_ENV=cron.env` and
  `init-cron.sh` regenerates `cron.env` each boot from the live `claude` env —
  `CLAUDE_CONFIG_DIR`, `PATH`, auth, and the `PG*`/`DATABASE_URL` client vars so
  scheduled jobs can reach the db (`CRON_ENV_VARS` is a hand-maintained allowlist of
  names). The daemon starts root-via-`sudo` behind a `pgrep -x cron` guard so
  entrypoint + postStartCommand can't double-start it.

## DB sidecar (`compose.yaml`, `gen-env.sh`, Makefile)
- **DB password applies only on first init of `claude-pgdata`.** Editing `.env`
  later does NOT re-key a running DB — `make db-reset` (destroys data) does. The
  sidecar is opt-in via the `db` compose profile (`make db-up`); the pg18 *client*
  in the image must match the server major (PGDG `postgresql-client-18`, not
  Debian's 15).
- **`.env` is read at container *create* time, not start.** It must exist before
  `claude-code` is created; `make up`/`db-up` and `devcontainer.json`'s
  `initializeCommand` (`gen-env.sh`) guarantee it. A container born too early has an
  empty `DATABASE_URL` — fix with `--force-recreate` (a plain `restart` re-reads
  nothing). `.env` lives on the host only.
- **Lifecycle teardown targets are profile-aware** (`COMPOSEDB := $(COMPOSE)
  --profile db`): `stop`/`down`/`nuke` all route through `$(COMPOSEDB)`, so they
  actually stop/remove `claude-db` and (for `nuke`) the in-use `claude-pgdata`
  volume. A bare `$(COMPOSE) down -v` leaves the profiled db running and can't
  remove the volume — don't drop the `--profile db`.
- **Two load-bearing `db` settings** (keep the inline comments):
  `PGDATA=/var/lib/postgresql/data/pgdata` (subdir — pg18 refuses to init at the
  mount root) and `PGHOST: ""` (the shared `.env` injects `PGHOST=db` into the
  server container too, which would point its healthcheck at itself).

## pgAdmin (`compose.yaml` `pgadmin`, `gen-env.sh`, Makefile `pgadmin-*`)
- **Own secret file, not `.env`.** `pgadmin.env` is pgadmin's only `env_file`.
  Moving the login into `.env` would inject it into claude-code/db and change
  their config hash, which recreates both on the next `up`. The db password
  reaches pgAdmin only through the interpolated `pgadmin-pgpass` config.
  `gen-env.sh` creates each file independently, so existing installs gain it.
- **Imported on FIRST INIT ONLY.** The entrypoint creates the login, loads
  `servers.json`, and copies `PGPASS_FILE` to `storage/<email, @→_>/.pgpass`
  (where `"passfile": "/.pgpass"` resolves in server mode), all only while
  `pgadmin4.db` is absent. A recreate changes none of it; `make pgadmin-reset`
  does. Don't add `PGADMIN_REPLACE_SERVERS_ON_STARTUP`: its `--replace` clears
  every server the user added in the UI.
- **Port 8080 is tied to `cap_drop: [ALL]` + `no-new-privileges`.** Both defeat
  the file-capped python that binds :80, and the same setting blocks `sudo`
  (hence postfix off). Keep `PGADMIN_LISTEN_PORT`, the `5050:8080` mapping and
  the healthcheck URL in sync.
- The pgpass config's `uid: "5050"` + `mode: 0400` are load-bearing: compose's
  default is `0444 root`, which leaves the db password world-readable. The login
  email must pass pgAdmin's validator: it rejects `.local`/`.test`/`localhost`,
  while the reserved `example.com` passes.

## Observability (`log-event.sh`)
- **Boot emits a JSONL event trail.** `log-event.sh` (fire-and-forget; sourced by
  entrypoint/firewall/seed/cron with a no-op fallback) appends ts/seq/boot_id/phase/
  event records under `~/.claude`. `BOOT_ID` is generated ONCE in `entrypoint.sh`
  and threaded through the `sudo` firewall call as an explicit `VAR=val` (same
  `env_reset` reason as `FIREWALL_MODE`) so the firewall's events share the boot's
  id. `make boot-check` asserts the lifecycle events appear in order. Keep BOOT_ID on
  the sudo line; keep logging fire-and-forget (never let it fail the operation).
