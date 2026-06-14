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
  fallback), NOT any-destination; and there is NO blanket `--dport 22` rule —
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
  ARGs, zsh plugins by tag + asserted commit SHA; the two third-party apt keys
  (GitHub CLI, PGDG) fingerprint-verified. Bump a version *and* its paired checksum
  together — a mismatch fails the build by design. Keep the `SHELL [… -o pipefail …]`
  line (DL4006 fix) so `curl | sh` layers stay fail-closed. Don't revert any to
  floating `latest`/`main`.
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

## Observability (`log-event.sh`)
- **Boot emits a JSONL event trail.** `log-event.sh` (fire-and-forget; sourced by
  entrypoint/firewall/seed/cron with a no-op fallback) appends ts/seq/boot_id/phase/
  event records under `~/.claude`. `BOOT_ID` is generated ONCE in `entrypoint.sh`
  and threaded through the `sudo` firewall call as an explicit `VAR=val` (same
  `env_reset` reason as `FIREWALL_MODE`) so the firewall's events share the boot's
  id. `make boot-check` asserts the lifecycle events appear in order. Keep BOOT_ID on
  the sudo line; keep logging fire-and-forget (never let it fail the operation).
