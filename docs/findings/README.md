# Devcontainer Audit — Findings

## Executive summary

This audit covers the `claude-sandbox` devcontainer: its Dockerfile and build-time
tool installation, the layered default-deny egress firewall, the boot/startup
orchestration, the persisted cron subsystem, the opt-in Postgres sidecar, and the
surrounding documentation. The container is functionally solid and unusually
well-documented for its size — the `CLAUDE.md` invariant list captures many
genuinely load-bearing gotchas. However, the security posture has real holes that
undercut the project's central promise of a constrained sandbox. The firewall can
**fail open**: a mid-script abort under `set -euo pipefail` (no trap) leaves
`OUTPUT` policy at `ACCEPT` on bare re-runs, the rules are **IPv4-only** (all IPv6
egress bypasses the allowlist on dual-stack hosts), and strict mode unconditionally
permits **udp/53 and tcp/22 to any host** (DNS-tunnel and SSH-tunnel exfil
channels). A documented feature — `@aws-ip-ranges <region>` narrowing — is broken
by a jq bug that silently loads **zero** CIDRs, contradicting the docs that claim it
"can't break login." The entire build is **fetch-latest with no pinning,
checksums, or signatures** (base image, ~50 apt packages, 11 cargo binaries, npm
globals, AWS CLI, yq, lazygit, and several `curl | bash` installers), so the image
is neither reproducible nor tamper-evident. Several Makefile lifecycle targets
(`nuke`/`stop`/`down`) silently skip the profiled `db` sidecar, so `make nuke`'s
"destroys data" claim is false when the DB is up. There is **no CI, no shellcheck,
no smoke test** for a deliverable that is essentially shell + Docker config. None of
these brick the container today, but collectively they mean strict mode provides a
weaker guarantee than advertised and regressions in the load-bearing scripts would
ship undetected.

## Severity counts

| Severity  | Count |
|-----------|------:|
| Critical  |     1 |
| High      |    17 |
| Medium    |    39 |
| Low       |    28 |
| Nit       |     5 |
| **Total** | **90** |

## Top risks

The highest-severity confirmed findings:

- **[Critical] Firewall fails OPEN on a mid-script abort** — `init-firewall.sh`
  opens `OUTPUT ACCEPT` early to fetch GitHub/AWS ranges and re-clamps to `DROP` at
  the end, with no `trap` to fail closed. Any non-zero command in that window
  (under `set -euo pipefail`) aborts with egress wide open. Documented bare re-runs
  (in-container agents refreshing CDN IPs, `make firewall`, the VS Code
  `postStartCommand`) have no retry wrapper, so a single abort silently disables the
  firewall mid-session. (seq 1, `.devcontainer/init-firewall.sh:180`)
- **[High] Egress firewall is IPv4-only** — every rule is `iptables`/IPv4 and the
  ipset is `hash:net`; there is no `ip6tables` anywhere. On any IPv6-enabled Docker
  host the container reaches every AAAA destination over completely unfiltered IPv6,
  defeating default-deny. (seq 18, 38)
- **[High] Strict mode allows udp/53 and tcp/22 to ANY host** — unconditional DNS
  and SSH egress bypass the allowlist, giving a compromised dependency or agent
  ready-made DNS-tunnel and SSH-tunnel exfiltration channels. (seq 4, 33, 36, 82)
- **[High] `@aws-ip-ranges <region>` loads ZERO CIDRs** — a jq bug
  (`$reg|index(.region)` rebinds `.` to the array) makes the documented region-
  narrowing form fail silently, killing all AWS egress including GLOBAL/CloudFront
  — the exact opposite of the doc's "narrowing can't break login." (seq 2, 3)
- **[High] VS Code path swallows firewall failure** — `postStartCommand` is
  `A && B ; C || true`, so the overall exit is always 0 regardless of whether
  `init-firewall.sh` succeeded; VS Code opens a "healthy" workspace with the
  firewall absent. (seq 30)
- **[High] Whole build is fetch-latest, unpinned and unverified** — no base-image
  digest, no apt/cargo/npm pins, no checksums or signatures, `curl | bash`
  installers (cargo-binstall from `main`, uv, Claude), AWS CLI/yq/lazygit from
  `latest`. Non-reproducible and a standing supply-chain target running as root at
  build time. (seq 10, 39, 40, 41, 42, 43, 46, 70)
- **[High] `make nuke` does not destroy DB data when the sidecar is up** —
  lifecycle targets omit `--profile db`, so `down -v` leaves `claude-db` running and
  cannot remove the in-use `claude-pgdata` volume; the "destroys data" docstring is
  false. (seq 22; related `stop`/`down`, seq 26)
- **[High] Cron jobs cannot reach Postgres** — `cron.env` omits all
  `PG*`/`DATABASE_URL` vars, so scheduled `claude -p` / psql jobs fall back to the
  unix socket and fail, contradicting `seed/CLAUDE.md`'s promise that DB env "is
  handled for you." (seq 20)
- **[High] Dockerfile lacks `SHELL ... pipefail`** — `curl ... | bash` install
  layers mask curl failures, so a transient download error can bake a half-installed
  Claude/uv into a layer Docker caches as success. (seq 10, 34)
- **[High] Adding a script means editing 3 Dockerfile lists in lockstep** — COPY /
  CRLF-strip / chmod are hand-maintained; omitting a script from one list silently
  breaks the documented LF or exec-bit invariant on a Windows checkout or after a
  `docker cp`. (seq 50)

## Findings by area

| File | Area | Findings |
|------|------|---------:|
| [01-firewall.md](01-firewall.md) | firewall | 9 |
| [02-build.md](02-build.md) | build | 8 |
| [03-startup.md](03-startup.md) | startup | 2 |
| [04-cron.md](04-cron.md) | cron | 2 |
| [05-db.md](05-db.md) | db | 7 |
| [06-shell.md](06-shell.md) | shell | 1 |
| [07-config.md](07-config.md) | config | 1 |
| [08-docs.md](08-docs.md) | docs | 2 |
| [09-security.md](09-security.md) | security | 5 |
| [10-portability.md](10-portability.md) | portability | 1 |
| [11-supply-chain.md](11-supply-chain.md) | supply-chain | 10 |
| [12-idempotency.md](12-idempotency.md) | idempotency | 1 |
| [13-maintainability.md](13-maintainability.md) | maintainability | 12 |
| [14-boot-order.md](14-boot-order.md) | boot-order | 2 |
| [15-test-ci.md](15-test-ci.md) | test-ci | 6 |
| [16-perf-build.md](16-perf-build.md) | perf-build | 5 |
| [17-docs-accuracy.md](17-docs-accuracy.md) | docs-accuracy | 6 |
| [18-security-hardening.md](18-security-hardening.md) | security-hardening | 5 |
| [19-observability.md](19-observability.md) | observability | 5 |

> **Source of truth:** [`findings.jsonl`](findings.jsonl) is the machine-readable
> record — one compact JSON object per finding, in ascending `seq` order, each
> carrying the full finding fields plus the audit emit timestamp (`ts`). The
> per-area Markdown files and this index are derived views; when they disagree with
> the JSONL, the JSONL wins.
