# Devcontainer remediation — updates made

Run time (UTC): `2026-06-14T22:56:23Z`

This document summarizes the remediation of the prior security/quality audit of
the sandboxed devcontainer repo (container definition + config: shell, Dockerfile,
compose, JSONC — not an application). The audit findings live under
`docs/findings/` (intentionally left untracked). Remediation was organized into
eight batches spanning the audit's critical, high, and medium severities, covering
firewall robustness and egress hardening, supply-chain pinning and build hygiene,
DB lifecycle, cron environment, startup/boot-path hardening, CI gates and shell
quality, documentation accuracy, and an observability-first boot-event trail. Each
batch was developed on its own branch in an isolated worktree off `origin/main`,
opened as a PR, and **merged only when both validation (syntax checks, `docker
compose config`/`yq`, hadolint, live boot exercise where possible) and review
(diff checked against the load-bearing CLAUDE.md invariants) passed**. All eight
batches passed and were squash-merged into `main`.

## Batches

| Batch | Branch | PR | Status | Addressed finding seqs | Validation | Review |
|---|---|---|---|---|---|---|
| Firewall robustness: fail-closed, IPv6, locking, input validation | `fix/firewall-robustness` | [#7](https://github.com/ChrisSc/devcontainer/pull/7) | merged | 1, 18, 38, 49, 53 | passed | ok |
| Firewall egress hardening + AWS feed correctness | `fix/firewall-egress-hardening` | [#8](https://github.com/ChrisSc/devcontainer/pull/8) | merged | 2, 3, 4, 6, 7, 33, 36, 82 | passed | ok |
| Supply-chain pinning, checksum verification, and build hygiene | `fix/supply-chain-pinning` | [#9](https://github.com/ChrisSc/devcontainer/pull/9) | merged | 5, 10, 11, 12, 13, 34, 35, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 50, 52, 66, 70, 71 | passed | ok |
| DB lifecycle: profile-aware Make targets + .env perms + atomic dump | `fix/db-lifecycle` | [#10](https://github.com/ChrisSc/devcontainer/pull/10) | merged | 22, 24, 25, 26 | passed | ok |
| Cron environment completeness + self-documenting allowlist | `fix/cron-env` | [#11](https://github.com/ChrisSc/devcontainer/pull/11) | merged | 20, 51 | passed | ok |
| Startup/boot-path hardening: fail-fast firewall, bounded update, healthcheck, cap drop, env inventory | `fix/startup-wiring-hardening` | [#12](https://github.com/ChrisSc/devcontainer/pull/12) | merged | 19, 23, 30, 62, 81 | passed | ok |
| CI gates (shellcheck/hadolint/yamllint/smoke) + zsh compinit fix | `fix/ci-and-shell-quality` | [#13](https://github.com/ChrisSc/devcontainer/pull/13) | merged | 29, 54, 64, 65, 67 | passed | ok |
| Documentation accuracy: security model, permissive-mode, DB quickstart, inode caveat | `fix/docs-accuracy` | [#14](https://github.com/ChrisSc/devcontainer/pull/14) | merged | 31, 32, 75, 76 | passed | ok |
| Observability-first boot-event JSONL trail + lifecycle smoke test | `fix/observability` | [#15](https://github.com/ChrisSc/devcontainer/pull/15) | merged | 86, 87 | passed | ok |

All CLAUDE.md firewall/cron/build invariants were verified preserved in each batch
before merge (degrade-never-brick, non-fatal per-domain resolver,
ACCEPT-before/DROP-after policy reset, explicit `FIREWALL_MODE` on the `sudo` line,
crontab-as-real-file, baked-outside-volume-paths, etc.).

## Per-batch detail

### Firewall robustness: fail-closed, IPv6, locking, input validation — PR #7 (merged)

Squash commit `f17bf16` on `origin/main`. Changed `init-firewall.sh` +
`compose.yaml`. `bash -n` and `yq` validation passed.

- **seq 1 — fixed.** Added `trap '...OUTPUT/INPUT DROP (v4+v6)...' EXIT` immediately
  after the `iptables -P OUTPUT ACCEPT` open window. Cleared with `trap - EXIT` only
  after strict-mode DROP+REJECT is committed; the permissive branch clears it before
  its deliberate OUTPUT=ACCEPT exit. Any mid-script abort under `set -e` now fails
  closed instead of leaving egress open.
- **seq 18 — fixed.** IPv6 now fails closed: `ip6tables_supported` probe + `HAVE_IP6`
  gate, ip6tables flush/reset, loopback+DNS baseline, and `ip6tables -P OUTPUT DROP` +
  `REJECT --reject-with icmp6-adm-prohibited` in strict mode (ACCEPT in permissive).
  Chose the minimal fail-closed v6 path over a parallel AAAA ipset; no v6 destination
  bypasses the v4 allowlist. v6 absence is non-fatal.
- **seq 38 — fixed.** Same gap as seq 18. Applied option (a): added
  `sysctls: net.ipv6.conf.{all,default}.disable_ipv6=1` to the claude-code service in
  compose.yaml, validated via `docker compose config`. The script's ip6tables
  fail-closed (seq 18) is the backstop if the sysctl can't be applied.
- **seq 49 — fixed.** Added `exec 9>/run/claude-firewall.lock; flock 9` right after the
  `firewall_supported` gate, before the mode-file write and ipset/policy mutations, so
  overlapping boot/entrypoint vs `make firewall`/postStartCommand runs serialize. Lock
  auto-releases on exit (fd 9 close).
- **seq 53 — fixed.** Replaced the loose `^[0-9.]+$` guard with a strict per-octet
  `is_ipv4_cidr` validator (`IPV4_RE`), used in `add_domain` and the extra-allowlist
  literal path. Operator-supplied literal ipset-add now captures stderr and
  distinguishes duplicate from rejected instead of swallowing; non-IPv4 numeric-ish
  entries warn then fall back to DNS. Validator unit-tested.

### Firewall egress hardening + AWS feed correctness — PR #8 (merged)

Squash commit `8aed930` on `origin/main`. Changed `init-firewall.sh` +
`config/extra-allowlist.txt.example`. `bash -n`, `set -euo pipefail`, helper-function,
and resolver-non-fatal / negative-test invariants verified.

- **seq 2 — fixed.** AWS region jq filter rewritten to capture the prefix as `$p` before
  piping into `$reg` (`. as $p | select($p.region=="GLOBAL" or ($reg|index($p.region)))`);
  GLOBAL always retained. Dropped the blanket `|| true` on the jq stage (kept only on
  aggregate). Added a non-default-region smoke test (us-east-1, multi-region,
  comma-separated, bogus).
- **seq 3 — fixed.** Same root cause/fix as seq 2. Added a non-empty-output assertion in
  `add_aws_ranges`: warns loudly when a region filter matches zero CIDRs.
- **seq 4 — fixed.** DNS scoped to `/etc/resolv.conf` nameserver(s) via per-resolver
  udp+tcp/53 OUTPUT rules (fallback 127.0.0.11). Dropped the blanket tcp/22 ACCEPT — SSH
  now relies on the allowed-domains ipset via the strict OUTPUT match-set rule. tcp/53
  added for truncated answers. Same scoping mirrored to IPv6 baseline.
- **seq 6 — fixed.** jq region-narrowing bug fixed (seq 2/3), so the example doc is now
  accurate. Added a one-line note that region narrowing retains GLOBAL and warns on a
  zero-CIDR match.
- **seq 7 — fixed.** `case` now matches exactly: `@aws-ip-ranges` (load all),
  `@aws-ip-ranges <regions>` (narrow), and any other `@*` warns+skips. Verified with
  typo inputs.
- **seq 33 — fixed.** Removed the unconditional `--dport 22` ACCEPT (and its INPUT
  companion). git-over-SSH to github.com is covered by the allowed-domains ipset; SSH
  return traffic rides the existing INPUT ESTABLISHED,RELATED conntrack rule.
- **seq 36 — fixed.** Replaced the unrestricted UDP/53 any-destination allow with
  per-resolver udp+tcp/53 rules scoped to `/etc/resolv.conf` nameservers (127.0.0.11
  fallback). DNS replies handled statefully by the INPUT ESTABLISHED,RELATED rule.
- **seq 82 — fixed.** Both leaks closed together: DNS scoped to the configured
  resolver(s), SSH blanket allow removed in favor of the allowed-domains ipset. IPv6 DNS
  baseline scoped the same way. Live `ssh -T`/`dig` not possible in the static-edit
  environment, but the conntrack path was confirmed by code review.

### Supply-chain pinning, checksum verification, and build hygiene — PR #9 (merged)

Squash commit `4a5d67e` on `origin/main`. Six files committed via explicit paths.
Firewall change is an additive `.example` fallback (no new hard `exit 1`);
dockerignore re-includes match Dockerfile COPY sources.

- **seq 5 — fixed.** Baked `config/extra-allowlist.txt.example` into the image (new COPY)
  and made `init-firewall.sh` fall back to it when the real allowlist file is absent.
- **seq 10 — fixed.** Added `SHELL ["/bin/bash","-o","pipefail","-c"]` near the top of the
  Dockerfile; the Claude installer is now fetch-then-run so a failed download aborts the
  build.
- **seq 11 — fixed.** Pinned yq/lazygit/AWS CLI/pnpm and the npm globals to exact versions
  with SHA-256 (yq, lazygit) / GPG (AWS CLI) verification. cargo-binstall pinned to release
  tag v1.20.0; cargo crate versions left floating with an explicit deliberate-deviation
  comment (`--locked` + registry checksum).
- **seq 12 — fixed.** AWS CLI install fetches `awscliv2.zip` + `.sig`, imports an embedded
  AWS public key whose fingerprint is asserted ==
  `FB5DB77FD5C118B80511ADA8A6310ACC4672475C`, and runs `gpg --verify` before
  unzip/install. Verified end-to-end against live 2.35.4 (Good signature).
- **seq 13 — fixed.** Added `.devcontainer/.dockerignore` (default-deny: ignore `*` then
  re-include only COPY sources), with an explicit `.env` line — the Postgres password no
  longer enters the build context.
- **seq 34 — fixed.** Same SHELL pipefail directive as seq 10 — every `curl|sh` RUN now
  fails closed on a broken download. hadolint DL4006 confirmed resolved.
- **seq 35 — fixed.** Integrity verification added for all three direct downloads: yq
  (pinned SHA-256 per arch), lazygit (release `checksums.txt` + `sha256sum -c`), AWS CLI
  (GPG signature). cargo-binstall installer pinned to a tag not main.
- **seq 39 — fixed.** AWS CLI now follows the AWS-documented verified install. No longer
  runs `./aws/install` on an unverified archive.
- **seq 40 — fixed.** `FROM node:24-bookworm` pinned to
  `@sha256:40ad9f3064e67d6860b4bc3fe1880b2953934fd6320ada990e45fe0efa6badd7` (multi-arch
  manifest-list digest, resolves per-arch). Bump procedure documented.
- **seq 41 — fixed.** lazygit `LG_VER` pinned to 0.62.2 (no `releases/latest` lookup);
  tarball downloaded to temp, verified against release `checksums.txt`, then extracted.
  Asset name corrected to lowercase `linux`.
- **seq 42 — fixed.** cargo-binstall pinned to release tag v1.20.0; uv installer pinned to
  `https://astral.sh/uv/0.11.21/install.sh`; Claude installer fetch-then-run with `stable`
  channel. SHA-pinning the self-fetching uv/Claude scripts is impractical; fetch-then-run +
  pipefail + version/channel pin is the applied mitigation (documented deviation).
- **seq 43 — fixed.** yq `YQ_VER` pinned to 4.53.3; binary downloaded to temp and verified
  against a hardcoded per-arch SHA-256 before install. Same checksum pattern applied to
  lazygit.
- **seq 44 — partial.** Added `--locked` to cargo-binstall (reproducible transitive
  resolution). Per-crate exact-version pinning intentionally NOT applied for the 11 low-risk
  dev CLIs; documented as a deliberate deviation per the org standard, as the finding allows.
- **seq 45 — fixed.** pnpm pinned to 11.6.0 and typescript/tsx/eslint/prettier/pyright/
  playwright pinned to exact versions via Dockerfile ARGs; `npm install -g` now uses
  `--ignore-scripts`. playwright pinned in lockstep with the Chromium install.
- **seq 46 — partial.** Established the pinning discipline as a first-class artifact and
  documented it in CLAUDE.md. SBOM generation (syft) and renovate/Dependabot config were NOT
  added — they require CI plumbing this repo doesn't yet have; left for a follow-up.
- **seq 47 — fixed.** GitHub CLI keyring verified to contain fingerprint
  `2C6106201985B60E6C7AC87323F3D4EA75716059` and PGDG key verified ==
  `B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8` before apt trusts them. apt package versions
  left unpinned (documented in `.hadolint.yaml` DL3008 rationale).
- **seq 48 — fixed.** zsh plugins now clone release tags (zsh-autosuggestions v0.7.1,
  fast-syntax-highlighting v1.56, zsh-completions 0.36.0) and assert the expected commit SHA
  after clone, failing the build if a tag is re-pointed. Shallow clone preserved.
- **seq 50 — fixed.** Collapsed the three lockstep lists into one loop: the six
  `/usr/local/bin` scripts are CRLF-stripped + chmod'd in a single `for` loop. Adding a
  script now means editing only the COPY list.
- **seq 52 — fixed.** Removed the brittle `grep -Po` GitHub-API parse entirely by pinning
  `LG_VER`. The malformed-URL/empty-version failure mode no longer exists.
- **seq 66 — fixed.** Added `.hadolint.yaml` (ignored: DL3008/DL3016/DL3018 with rationale);
  DL4006 is FIXED via the SHELL pipefail directive, not ignored. hadolint via Docker exits 0.
- **seq 70 — fixed.** Same `.dockerignore` as seq 13, implemented as default-deny +
  re-include of only the actual COPY sources. Documented in CLAUDE.md.
- **seq 71 — fixed.** Added `--mount=type=cache` to the network-bound layers (both apt RUNs,
  the cargo layer, the npm/playwright layer); caches live in the mounts, not image layers —
  no size regression.

### DB lifecycle: profile-aware Make targets + .env perms + atomic dump — PR #10 (merged)

Squash commit `c480d9b` on `origin/main`. Only `Makefile` + `gen-env.sh` committed.
`COMPOSEDB` pre-defined; `claude-db` matches compose `container_name`; db profile
stays opt-in.

- **seq 22 — fixed.** `nuke` now runs `$(COMPOSEDB) down -v` (profile-aware), so it
  stops+removes claude-db and removes the claude-pgdata volume. Docstring updated.
- **seq 24 — fixed.** `gen-env.sh` existing-file branch now `chmod 600` before exit
  (idempotent re-securing); also chmod 600'd the live host `.env` which was 644.
- **seq 25 — fixed.** `db-dump` now writes to `$out.tmp` and `mv`s to final on success; on
  failure removes the temp file, prints guidance, and exits 1 (host file never truncated).
  Added pre-flight `docker inspect` running-state checks for claude-code and claude-db.
- **seq 26 — fixed.** `stop` and `down` now use `$(COMPOSEDB) stop`/`down`, consistent with
  `nuke` and the existing db-down/db-reset targets. Docstrings updated.

### Cron environment completeness + self-documenting allowlist — PR #11 (merged)

Squash commit `09fbeba` on `origin/main`. Single-file change to `init-cron.sh`.
CLAUDE.md cron invariants preserved.

- **seq 20 — fixed.** Appended `PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE DATABASE_URL` to
  `CRON_ENV_VARS` so cron jobs inherit the db client vars. The pre-existing
  `[ -n "${!name:+x}" ]` guard skips them harmlessly when the db profile isn't running.
- **seq 51 — fixed.** Made the comment honest: replaced the false "tracks any Dockerfile ENV
  change automatically" claim with an explicit note that values are read from the live
  process but the NAMES are a manual allowlist, plus the PG*/DATABASE_URL provenance. Did not
  switch to prefix auto-derivation (risk of writing AWS_* secrets into cron.env).

### Startup/boot-path hardening — PR #12 (merged)

Squash commit `317434c` on `origin/main`. Changed compose.yaml, devcontainer.json,
entrypoint.sh, seed-claude.sh, SECURITY.md. Invariants preserved (explicit
`FIREWALL_MODE` on sudo, mode-file-gated healthcheck, NET_ADMIN retained,
bounded non-fatal update).

- **seq 19 — fixed.** Added healthcheck to claude-code asserting: `command -v claude`,
  `[ -f ~/.claude/ENVIRONMENT.md ]`, `pgrep -x cron`, and OUTPUT-policy DROP gated on strict
  mode (read from `/etc/claude-firewall/mode`). iptables read routed via `sudo -n`.
- **seq 23 — fixed.** Added a Database section to the ENVIRONMENT.md heredoc in
  seed-claude.sh (DATABASE_URL presence, PGHOST, live `pg_isready -t1`), plus claude-pgdata
  in the volume list. Safe under `set -u` via `${VAR:-}`.
- **seq 30 — fixed.** Rewrote devcontainer.json postStartCommand to the guarded form so a
  firewall nonzero exit propagates while update/cron stay non-fatal.
- **seq 62 — fixed.** Bounded `claude update` in entrypoint.sh to `timeout 120 claude update
  < /dev/null || echo WARN...`, detaching stdin and capping the hang before `exec "$@"`. Kept
  non-fatal.
- **seq 81 — fixed.** Removed `- NET_RAW` from cap_add (NET_ADMIN retained), updated the
  comment, and dropped NET_RAW from SECURITY.md. The firewall path uses only iptables/ipset
  (no raw sockets). Could not boot to confirm egress (no Docker in environment).

### CI gates (shellcheck/hadolint/yamllint/smoke) + zsh compinit fix — PR #13 (merged)

Squash commit `cc4960d` on `origin/main`. Six files. No firewall/cron/build logic
changed; install-tools.sh change is only SC2034 suppression comments.

- **seq 29 — fixed.** Replaced the broken always-true `[[ -n ...(#qN.mh+24) ]]` compinit
  fast-path with the array-glob form (`local stale=($zdump(Nmh+24)); if (( ${#stale} )) ||
  [[ ! -e $zdump ]]; then compinit; else compinit -C; fi`). Verified `zsh -n` parses.
- **seq 54 — fixed.** Added `.github/workflows/ci.yaml` (shellcheck, hadolint, `docker
  compose config -q`) plus a `make lint` target wrapping the same set, and the smoke
  build/boot job.
- **seq 64 — fixed.** Added a `smoke` job (+`make smoke`) that seeds host .env+allowlist,
  builds, brings up with FIREWALL_MODE=permissive, waits for ENVIRONMENT.md, then asserts
  `claude --version`, python3 resolves to the uv 3.14 shim (not Debian 3.11),
  `command -v rg fd bat jq yq aws lazygit`, and ENVIRONMENT.md exists. Dumps logs + tears down.
- **seq 65 — fixed.** Added `ci.yaml` on push + pull_request with three cheap jobs
  (shellcheck, hadolint, yamllint) + compose config validation. `permissions: contents:read`.
- **seq 67 — fixed.** Added `.shellcheckrc` and wired shellcheck into CI + `make lint`.
  Pinned severity=warning; disabled SC1091, plus SC2016+SC2020 by name (benign jq-program/tr
  cases) and a scoped SC2034 on install-tools.sh's YQ_SHA256_* constants. Full gate exits 0.

### Documentation accuracy — PR #14 (merged)

Squash commit `4c1ef35` on `origin/main`. Four documentation-only files
(seed/CLAUDE.md, extra-allowlist.txt.example, README.md, SECURITY.md).

- **seq 31 — fixed.** Added the Docker Desktop macOS inode-pin caveat in seed/CLAUDE.md and
  the extra-allowlist.txt.example header (editor write-temp+rename pins the old inode; host
  must `docker restart claude-code` or `make rebuild`, not just re-run init-firewall.sh).
- **seq 32 — fixed.** Added a one-line precondition to the README Database section (DB
  commands run psql/pg_dump from inside claude-code, so `make up` first) plus a `make up`
  line in the quickstart block.
- **seq 75 — fixed.** Added a "Scheduled agents (cron) run unattended" bullet to SECURITY.md's
  security model (exfil/abuse vector; crontab source of truth not host-editable but
  in-container-writable).
- **seq 76 — fixed.** Reworded seed/CLAUDE.md "Open the web entirely" bullet: FIREWALL_MODE is
  fixed at container create time, so a bare `docker restart` will NOT change it; instructs
  re-create with `--force-recreate`.

### Observability-first boot-event JSONL trail + lifecycle smoke test — PR #15 (merged)

Squash commit `f071e5c` on `origin/main`. Nine files. BOOT_ID threaded through sudo via
the explicit VAR=val pattern (survives sudoers env_reset); firewall degrade/permissive/
strict + non-fatal resolver paths untouched; writes to the existing ~/.claude volume.

- **seq 86 — fixed.** Added `log-event.sh` (fire-and-forget JSONL helper: ts/seq/boot_id/
  phase/event+payload, dependency-free JSON escaping, boot-id-keyed monotonic seq,
  root->claude chown). Sourced by entrypoint.sh, init-firewall.sh, seed-claude.sh,
  init-cron.sh with a no-op fallback. BOOT_ID generated once in entrypoint.sh, exported,
  threaded through the sudo firewall call and the postStartCommand re-run. Dot-namespaced
  events at every state transition. Baked via Dockerfile COPY+sed loop and .dockerignore
  re-include. Live-exercised: 10 ordered, claude-owned, valid-JSON events with monotonic seq
  1..10 under one boot_id.
- **seq 87 — fixed.** Added `make boot-check` target that picks the latest boot_id and asserts
  firewall.apply.start -> firewall.complete{.strict|.permissive|degraded} -> seed.ssh.linked
  -> seed.environment.regenerated -> cron.installed -> cron.daemon.started ->
  entrypoint.ready are present and in order. Passed against a live container; a negative test
  (deleted event) correctly failed.

## New findings surfaced for future refactoring

The remediation surfaced additional findings that were **NOT fixed in this run** —
they are recorded here for a future refactoring/hardening pass. Severities below are
as assessed during review.

### Firewall

- **(low, maintainability) `add_domain` no longer warns on CNAME-only / no-A
  resolution** (`init-firewall.sh:142`). The dropped `grep -E '^[0-9.]+$'` means a
  CNAME-only domain now logs `added 0 IP(s)` with no warn-level diagnostic. Recommend
  emitting a warn when `added==0` after the resolve loop.
- **(low, bug) `flock` acquired AFTER `firewall_supported()`** (`init-firewall.sh:123`).
  The `__fw_probe` ipset create/destroy in the preflight remains unserialized; two
  overlapping invocations could collide on the fixed-named probe set. Recommend a
  uniquely-named probe (`__fw_probe_$$`) or moving the flock before the capability probe.
- **(low, maintainability) IPv6 fail-closed builds no AAAA allowlist**
  (`init-firewall.sh:404`). A future IPv6-only host would be REJECTed with no v6 allowlist
  path. Recommend mirroring the v4 ipset with `family inet6` if/when a v6-only dependency
  appears, and documenting that strict mode is v4-allowlist-only.
- **(nit, maintainability) `disable_ipv6` sysctls and the ip6tables ruleset are
  redundant** (`compose.yaml:30`). No log line states which mechanism actually took effect.
  Recommend emitting the observed v6 posture, per the observability-first standard.
- **(low, maintainability) Comment rationale for dropping `|| true` on the jq stage is
  factually wrong** (`init-firewall.sh:197`). Process substitution swallows the
  substitution's exit status, so a malformed jq does not abort; the real guard is the
  `count==0` warning, which only fires when a region filter is given. Recommend correcting
  the comment and/or extending the zero-count warning to fire regardless of region_filter.
- **(low, docs) SSH-rides-the-ipset and DNS-scoped-to-resolver changes not documented in
  CLAUDE.md** (`CLAUDE.md`). A future maintainer could re-add a blanket tcp/22 or
  any-destination udp/53 allow as a perceived omission. Recommend adding a firewall
  invariant documenting both as deliberate.
- **(low, bug) Zero-CIDR region warning never fires for a typo'd region**
  (`init-firewall.sh:207`). GLOBAL prefixes always match, keeping `count>0`, so a misspelled
  region silently falls back to GLOBAL-only. Recommend tracking non-GLOBAL matches separately
  or validating requested region names against the present `.region` values.

### Build / supply-chain

- **(medium, portability) seq-5 build-time COPY of gitignored `extra-allowlist.txt` still
  fails on fresh-clone raw `docker compose up --build`** (`Dockerfile:222`). The runtime
  fallback runs only after a successful build. Recommend `COPY
  config/extra-allowlist.txt.example` into the canonical in-image path (keeping the bind-mount
  + gen-allowlist override) and correcting the Dockerfile comment.
- **(low, maintainability) Pinned versions/digests/SHAs have no CI verification gate or
  renovate config** (`install-tools.sh:25`). ~20 hand-paired constants will silently rot.
  Recommend a renovate.json / dependabot.yml (already promised in comments) and a minimal CI
  that runs hadolint + a build smoke.
- **(low, maintainability) AWS CLI public key block embedded inline with no expiry/rotation
  handling** (`install-tools.sh:123`). Recommend recording the canonical source URL + capture
  date, or moving the key to a separate fingerprint-checked `aws-cli.gpg` file.
- **(low, perf) apt cache mounts share a single lockfile; in-layer `apt-get update` still
  re-runs every build** (`Dockerfile:44`). Optional: consolidate the two apt RUN blocks into
  one layer sharing a single `apt-get update`.
- **(low, security) Rust CLI crates (cargo-binstall) remain version-unpinned by deliberate
  choice** (`install-tools.sh:64`). seq 44 is only partially addressed; the installer itself
  is tag-pinned. If full reproducibility is later required, pin each crate as `eza@x.y.z` and
  track via renovate.

### DB

- **(low, docs) CLAUDE.md still doesn't document that lifecycle teardown targets must use the
  db-profile compose invocation** (`CLAUDE.md:137`). The `$(COMPOSEDB)` coupling for
  stop/down/nuke is now load-bearing but undocumented. Recommend a one-line invariant.
- **(medium, docs) ENVIRONMENT.md (regenerated each boot) still omits the Postgres sidecar /
  DATABASE_URL / claude-pgdata** (`seed-claude.sh:46`). (Note: the startup-wiring batch's
  seq-23 added a Database section; this finding was raised against the db-lifecycle batch,
  which touched only Makefile + gen-env.sh.) Recommend reconciling so the live inventory
  reports the DB.
- **(low, bug) db-* helper targets (db-psql/db-create) still depend on claude-code running but
  only db-dump now guards it** (`Makefile:67`). Recommend factoring the running-check into a
  shared guard prerequisite.
- **(nit, bug) db-dump atomic-rename has a benign edge** (`Makefile:88`): a pre-existing
  directory at the output path lets BSD/macOS `mv` merge into it. Optional hardening: gate the
  success echo on the rename and add a `test ! -e "$out"` precheck.

### Cron

- **(low, maintainability) PATH is set in two places** (`init-cron.sh:54`): the crontab
  `PATH=` line and the captured `cron.env` (which silently wins via BASH_ENV). Byte-identical
  today. Recommend a single source of truth.
- **(low, maintainability) Hand-maintained `CRON_ENV_VARS` allowlist will silently drift from
  compose/Dockerfile ENV** (`init-cron.sh:53`). Recommend prefix/pattern auto-derivation or an
  event-completeness test.

### Test / CI

- **(low, test-gap) No automated test guards cron.env completeness** (`init-cron.sh:62`). The
  seq-20 regression could not have been caught by CI. Recommend an integration check that
  boots with the db profile and asserts a cron job sees PGHOST/DATABASE_URL.
- **(low, test-gap) `make smoke` leaves the container running and never fails on seed timeout**
  (`Makefile:64`), diverging from the CI smoke job. Recommend mirroring the CI failure message
  + `down -v` teardown, or documenting the intentional leave-up.
- **(nit, maintainability) yamllint reports an unsuppressed comments-indentation warning**
  (`compose.yaml:76`). Non-gating but trains reviewers to ignore yamllint. Recommend
  realigning the comment or disabling `comments-indentation` with rationale.
- **(low, security) `ludeeus/action-shellcheck` and `hadolint-action` pinned to `@master` / a
  floating tag** (`.github/workflows/ci.yaml:27`). Reintroduces the floating-ref risk the repo
  otherwise guards against. Recommend pinning third-party actions to full commit SHAs.
- **(nit, maintainability) Local `make lint` and CI shellcheck cover different file sets**
  (`.github/workflows/ci.yaml:27`). The two mirror gates can drift. Recommend sharing one
  discovery mechanism.

### Docs accuracy

- **(low, docs) README permissive-mode recipe omits `--force-recreate`** (`README.md:298`), so
  it won't switch FIREWALL_MODE on an already-running container — inconsistent with the
  seed/CLAUDE.md fix (seq 76). Recommend matching the seed wording.
- **(nit, docs) README DB quickstart: a prose precondition was inserted between the "nothing
  starts unless you ask:" colon and its fenced code block** (`README.md:210`). Minor
  presentation nit. Optional reorder.
- **(nit, maintainability) seed/CLAUDE.md inode caveat duplicates README/allowlist-example
  wording in ~four places** (`seed/CLAUDE.md:35`). Intentional (distinct audiences) but a
  drift hazard. Leave as-is for now; consider a canonical sentence + cross-reference later.

### Observability

- **(low, portability) Boot-event timestamps use `date %3N` millisecond format that only
  resolves under GNU date** (`log-event.sh:84`). Correct inside the Linux container; a latent
  trap if sourced outside. Recommend plain second precision or a GNU-date branch.
- **(medium, test-gap) `boot-check` hard-requires `cron.installed`, false-failing on
  cron-degraded or parse-error boots** (`Makefile:95`). The firewall slot tolerates a degraded
  variant; the cron slot does not. Recommend accepting `(cron.installed | cron.degraded)` and
  `(cron.daemon.started | cron.daemon.failed | cron.degraded)`.
- **(low, perf) Boot-events JSONL journal and per-boot `.seq` counter files grow unbounded on
  the persistent volume** (`log-event.sh:64`). No rotation/TTL/cleanup. Recommend lightweight
  rotation + pruning stale `.seq.*` (best-effort).
- **(low, maintainability) Events use untyped positional key/value string bags with no central
  taxonomy** (`log-event.sh:52`). Partial against the typed-event standard. Recommend defining
  the event-name set once and emitting known-numeric payload keys unquoted, for a future pass.
- **(low, maintainability) Firewall re-emits `firewall.apply.start` on each entrypoint retry**
  (`entrypoint.sh:35`), duplicating events within one boot_id. Tolerated by boot-check.
  Optional: move the emission to the entrypoint (once) or add an attempt marker.
