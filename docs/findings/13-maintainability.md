# maintainability — audit findings

The maintainability of this repo is dominated by one structural theme: load-bearing logic that is hand-maintained in multiple places at once. There are no critical findings, but one high-severity item (a new script must be edited into three separate Dockerfile lists in lockstep, with silent cross-platform failures if any is missed) and a cluster of duplication findings across `init-firewall.sh` (CIDR validators, retry-3 fetch loops, strict-mode egress rules, log helpers). Two medium findings expose latent silent-failure bugs — a comment that lies about cron env-var tracking, and a loose IPv4 regex paired with a swallowed `ipset` error — and a separate medium gap is the absence of any CI / shellcheck / hadolint gate for a repo whose entire deliverable is ~700 lines of security-critical shell plus a Dockerfile. The lower-severity items are documentation-drift and DRY concerns that compound the same "edit it in N places or it diverges" risk. The single highest-leverage fix is adding static-analysis CI; the most broadly-felt fix is factoring the duplicated firewall helpers into one shared library.

## Adding a script requires editing 3 separate Dockerfile lists in lockstep (COPY / sed-CRLF / chmod)

- **Severity / kind:** high / maintainability
- **Location:** [.devcontainer/Dockerfile:144](.devcontainer/Dockerfile#L144)
- **Evidence:**
  > The same six script names (init-firewall.sh, entrypoint.sh, seed-claude.sh, init-cron.sh, crontab-reload, crontab-edit) are enumerated three times: COPY at :144-145, the `sed -i 's/\r$//'` CRLF-strip at :152-162, and `chmod +x` at :164-169. Each list is maintained by hand.
- **Why it matters:** These lists encode two documented invariants (CLAUDE.md: scripts must stay LF or the entrypoint dies with `bad interpreter: ...^M`; and `docker cp` drops the exec bit so scripts must be `chmod +x`). A new script added to COPY but omitted from the sed list ships CRLF-vulnerable on a Windows checkout; omitted from chmod, it lands non-executable and `sudo <script>` fails with 'command not found'. The failure is invisible until a Windows host or a specific code path hits it — exactly the silent-invariant-break the audit targets.
- **Recommendation:** Collapse to one loop: `COPY *.sh crontab-reload crontab-edit /usr/local/bin/` then a single `for f in /usr/local/bin/<glob>; do sed -i 's/\r$//' "$f"; chmod +x "$f"; done`. Or drive all three from one shell array. The .gitattributes LF enforcement already covers the CRLF case for git users, making the sed list pure belt-and-suspenders that nonetheless must not drift.

## Hand-maintained CRON_ENV_VARS allowlist contradicts its own comment claiming automatic Dockerfile-ENV tracking

- **Severity / kind:** medium / maintainability
- **Location:** [.devcontainer/init-cron.sh:49](.devcontainer/init-cron.sh#L49)
- **Evidence:**
  > Comment at init-cron.sh:48-49 says the cron env is 'Captured from the current process, so it tracks any Dockerfile ENV change automatically.' But the capture is gated by the explicit allowlist `CRON_ENV_VARS=( PATH HOME CLAUDE_CONFIG_DIR ... )` at :50-57, and only those names are emitted (loop at :61-66).
- **Why it matters:** The claim is false for the case that matters: adding a NEW environment variable to the Dockerfile's per-user ENV block (Dockerfile:175-186) does NOT propagate to cron jobs unless someone also appends it here. It only tracks value changes for already-listed vars. A future feature that relies on a new env var inside a `claude -p` cron job will work interactively and in the entrypoint but mysteriously fail under cron — the hardest class of bug to trace. (Confirmed: Dockerfile sets e.g. SHELL/AWS vars; the list is a manual subset.)
- **Recommendation:** Either make the comment honest ('explicit allowlist — add new vars here too') or actually auto-derive: snapshot the relevant exported env by prefix/pattern (e.g. all of CLAUDE_*, AWS_*, PNPM_*, plus a fixed core) rather than a literal name list, so a new `FOO_CONFIG=...` ENV is picked up without a second edit.

## lazygit version parsed from GitHub API JSON with brittle `grep -Po`, while jq is installed and used elsewhere in the same script's consumers

- **Severity / kind:** medium / maintainability
- **Location:** [.devcontainer/install-tools.sh:46](.devcontainer/install-tools.sh#L46)
- **Evidence:**
  > install-tools.sh:46-47 extracts the release tag via `curl ... releases/latest | grep -Po '"tag_name":\s*"v\K[^"]*'`. jq is installed at build time (Dockerfile:45 installs `jq` before install-tools.sh runs at :77) and init-firewall.sh parses GitHub's API with jq throughout.
- **Why it matters:** Regex-scraping structured JSON is fragile: it breaks if GitHub reorders/whitespaces fields, if a pre-release `tag_name` appears, or if rate-limited HTML/error JSON is returned (the `grep` then yields empty `LG_VER`, producing a download URL `.../download/v/lazygit__Linux_...` that 404s — and `curl -f | tar` fails the build with an opaque message). `grep -Po` is also GNU-only, a portability footgun the repo otherwise guards against. It is inconsistent with the codebase's own jq-based parsing convention.
- **Recommendation:** Replace with `jq -r .tag_name` and strip the leading `v`: `LG_VER=$(curl -fsSL .../releases/latest | jq -r '.tag_name | ltrimstr("v")')`, and guard `[ -n "$LG_VER" ] || { echo 'ERROR: could not resolve lazygit version' >&2; exit 1; }` so a parse failure fails loudly at build time instead of emitting a malformed URL.

## Loose IPv4 guard `^[0-9.]+$` admits malformed addresses; the subsequent ipset error is swallowed with no diagnostic

- **Severity / kind:** medium / bug
- **Location:** [.devcontainer/init-firewall.sh:106](.devcontainer/init-firewall.sh#L106)
- **Evidence:**
  > add_domain at :106 filters resolver output with `grep -E '^[0-9.]+$'`, which accepts `1.2.3`, `999.999.999.999`, `1..2`, etc. (verified). The same loose `^[0-9.]+(/[0-9]{1,2})?$` is used for literal allowlist entries at :248. The add at :113/:249 is `ipset add ... 2>/dev/null`, so when ipset rejects a malformed value the error is discarded and `added`/the success log is simply not incremented.
- **Why it matters:** A typo in extra-allowlist.txt (e.g. `192.168.1` or a fat-fingered CIDR) is accepted by the regex, silently rejected by ipset, and produces NO warning — the operator sees the firewall 'succeed' while their intended host is not actually allowed. Because the whole firewall is built for default-deny egress, a silently-dropped allowlist entry manifests later as an unexplained `no route to host`, which CLAUDE.md trains the user to blame on CDN IP rotation rather than a bad allowlist line. The swallowed-error pattern removes the one signal that would localize it.
- **Recommendation:** Use a real IPv4/CIDR validator (e.g. a per-octet regex `^((25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(25[0-5]|2[0-4]\d|1?\d?\d)(/\d{1,2})?$`) and, on `ipset add` failure for an operator-supplied literal, emit a `warn` instead of swallowing — distinguish 'duplicate (ok)' from 'rejected (bad input)'.

## No shellcheck / CI gate for the shell scripts that ARE the deliverable

- **Severity / kind:** medium / test-gap
- **Location:** [.devcontainer/init-firewall.sh](.devcontainer/init-firewall.sh)
- **Evidence:**
  > `fd` over `.github` returns no directory and `rg -l shellcheck` over the repo returns nothing — there is no CI workflow, no shellcheck config, and no test harness. The repo is ~700 lines of load-bearing bash (init-firewall.sh alone is 328) plus a Dockerfile, with security-critical logic (default-deny egress, sudo invocations, ipset population).
- **Why it matters:** For a repo whose entire product is shell + Docker config enforcing a security boundary, there is no automated guard against regressions: a quoting bug, an unquoted `$FIREWALL_MODE`, a `set -e` interaction, or a broken `case` could ship silently. The user's own global standards require running lint/format and a 'live exercise' gate; nothing here enforces even static analysis. Several findings above (duplicated CIDR regex, sed-vs-builtin) are exactly what shellcheck flags.
- **Recommendation:** Add a `.github/workflows/ci.yml` running `shellcheck` over `.devcontainer/*.sh` + `crontab-edit`/`crontab-reload`, `hadolint` over the Dockerfile, and `docker compose -f .devcontainer/compose.yaml config -q` to validate compose. Add a `make lint` target wrapping the same so it runs locally. This is the single highest-leverage maintainability addition.

## CIDR-validation regex `^[0-9.]+/[0-9]{1,2}$` and `ipset add ... 2>/dev/null` loop duplicated between GitHub-meta and AWS-ranges loaders

- **Severity / kind:** low / maintainability
- **Location:** [.devcontainer/init-firewall.sh:154](.devcontainer/init-firewall.sh#L154)
- **Evidence:**
  > The CIDR guard `[[ "$cidr" =~ ^[0-9.]+/[0-9]{1,2}$ ]] || continue` followed by `ipset add allowed-domains "$cidr" 2>/dev/null` appears identically in add_aws_ranges (:155-156) and the GitHub-meta block (:216-217), and a third near-variant in the literal-IP allowlist branch (:248). Same regex, three sites.
- **Why it matters:** All three ingest CIDR/IP lists into the same ipset with the same validation, but as separate inline copies. If the validation is tightened (per the loose-regex finding above) it must be fixed in every copy or the firewall validates inconsistently depending on the source (AWS feed vs GitHub feed vs operator literal) — a maintainability trap where one source is hardened and another silently is not.
- **Recommendation:** Factor a single `ipset_add_cidrs` function that takes a stream of candidate CIDRs, applies one canonical validator, and reports a count — call it from all three sites (it pairs naturally with the fetch-retry helper above).

## Duplicated log()/warn() helpers across scripts; no shared sourcing

- **Severity / kind:** low / maintainability
- **Location:** [.devcontainer/init-firewall.sh:65](.devcontainer/init-firewall.sh#L65)
- **Evidence:**
  > init-firewall.sh:65 `log()  { echo "[firewall] $*"; }` / :66 `warn() { echo "[firewall] WARN: $*" >&2; }` are duplicated verbatim (only the prefix differs) at init-cron.sh:25-26 `log()  { echo "[cron] $*"; }` / `warn()`. entrypoint.sh / seed-claude.sh / gen-*.sh instead hand-roll `echo "[entrypoint] ..."`, `echo "[seed] ..."` inline with no helper. A grep for `source`/`. ` across all scripts returns nothing — every script is standalone.
- **Why it matters:** Five startup/preflight scripts share the same logging idiom but re-implement (or inline) it independently. There is no common library, so any change to log format (e.g. adding a timestamp per the org observability standard, or routing to stderr) must be edited in many places and will drift. The org CLAUDE.md explicitly calls for injectable, consistently-formatted structured logging; the current ad-hoc echoes are the opposite.
- **Recommendation:** Add a single `.devcontainer/lib/common.sh` (also COPYed to /usr/local/lib) defining `log()`/`warn()` that take a prefix via a `LOG_PREFIX` var (e.g. `: "${LOG_PREFIX:=script}"`). Source it at the top of init-firewall.sh, init-cron.sh, entrypoint.sh, seed-claude.sh, gen-env.sh, gen-allowlist.sh and set `LOG_PREFIX` per script. This is the natural home for the other shared constants below.

## ENVIRONMENT.md persistent-volume list hardcoded, drift-prone against compose.yaml

- **Severity / kind:** low / docs
- **Location:** [.devcontainer/seed-claude.sh:82](.devcontainer/seed-claude.sh#L82)
- **Evidence:**
  > seed-claude.sh:82-85 hardcodes the volume table (`/workspace -> claude-workspace`, `/home/claude/.claude -> claude-config`, `/commandhistory -> claude-bashhistory`, `/home/claude/.local/share/pnpm -> claude-pnpm-store`). The authoritative mapping lives in compose.yaml:34-40 (mounts) and :85-95 (named volumes, incl. `claude-pgdata` which the snapshot omits).
- **Why it matters:** The live-environment doc claims to be the source of truth for what survives a rebuild, but it is a manually maintained copy of compose.yaml's volume list. Adding/removing a volume in compose (a new sidecar, splitting ~/.cache out) won't be reflected, so the regenerated-every-boot doc silently lies — the exact staleness this 'regenerate each boot' file was meant to avoid for tool versions.
- **Recommendation:** Generate the list at runtime instead of hardcoding it: in seed-claude.sh derive mounts from `findmnt` / `/proc/mounts` (filter docker volume mounts), or read compose.yaml volume names. At minimum add a comment in both seed-claude.sh and compose.yaml cross-referencing each other so the coupling is visible, and include claude-pgdata.

## GitHub-meta and AWS IP-range fetch loops duplicate curl-retry + jq|aggregate|CIDR-add logic

- **Severity / kind:** low / maintainability
- **Location:** [.devcontainer/init-firewall.sh:206](.devcontainer/init-firewall.sh#L206)
- **Evidence:**
  > Two near-identical pipelines: GitHub at :208-218 (`for attempt in 1 2 3` curl with `--connect-timeout 5`, jq `-e` validate, then `while read -r cidr; [[ "$cidr" =~ ^[0-9.]+/[0-9]{1,2}$ ]] ... ipset add ... done < <(... | jq -r ... | aggregate -q || true)`) and AWS at :134-159 (same retry-3 curl, same jq-validate, same `while read` with the identical CIDR regex `^[0-9.]+/[0-9]{1,2}$` and `aggregate -q || true`). The CIDR regex literal appears at both :155 and :216.
- **Why it matters:** The retry/validate/aggregate-into-ipset machinery is implemented twice with the same magic numbers (3 attempts, 5s connect timeout) and the same CIDR validation regex copy-pasted. Tuning retry behavior, the timeout, or the CIDR guard requires editing both blocks, and the duplicated regex can drift (e.g. one block gets IPv6 support, the other doesn't).
- **Recommendation:** In init-firewall.sh add `fetch_json_retry(url)` (the curl+retry loop, returning the body) and `add_cidrs_from(jq_output)` (the `while read` + CIDR-regex + `ipset add` loop). Hoist `RETRIES=3`, `CONNECT_TIMEOUT=5`, and the CIDR regex to named constants. Both the GitHub and AWS paths then reduce to: fetch, jq-extract, pipe through the shared CIDR loader.

## Strict-mode egress rules duplicated between `strict)` and `*)` cases

- **Severity / kind:** low / maintainability
- **Location:** [.devcontainer/init-firewall.sh:299](.devcontainer/init-firewall.sh#L299)
- **Evidence:**
  > The FIREWALL_MODE case at init-firewall.sh:299-310 has the `strict)` arm (300-302: `iptables -P OUTPUT DROP` + `--match-set allowed-domains dst -j ACCEPT` + `-j REJECT --reject-with icmp-admin-prohibited`) and the `*)` default arm (306-308) executing the exact same three iptables commands; only the extra `warn` differs.
- **Why it matters:** The default-deny egress rule set — the security-critical core of the firewall — is written twice. A change to how strict mode clamps OUTPUT (e.g. switching REJECT to DROP, or adding a logging rule) must be made in both arms or the 'unknown mode falls back to strict' path silently diverges from real strict mode, weakening or breaking the fallback that exists precisely for safety.
- **Recommendation:** Extract an `apply_strict_egress()` function (the three iptables lines) and call it from both the `strict)` and `*)` arms in init-firewall.sh. The `*)` arm keeps only its `warn` then calls the function.

## Three near-identical retry-3 fetch loops with no shared helper; each re-implements timeout, attempt logging, and the success predicate

- **Severity / kind:** low / maintainability
- **Location:** [.devcontainer/init-firewall.sh:208](.devcontainer/init-firewall.sh#L208)
- **Evidence:**
  > The `for attempt in 1 2 3; do ... curl -fsSL --connect-timeout 5 ...; [ -n "$x" ] && jq -e ...; warn 'attempt N failed'; done` shape is repeated in init-firewall.sh:134-140 (AWS ranges), init-firewall.sh:208-213 (GitHub meta), and structurally in entrypoint.sh:17-27 (firewall apply). Each hardcodes the attempt count and timeout independently.
- **Why it matters:** The retry-with-validation idiom is copy-pasted, so the connect-timeout (5s), retry count (3), and backoff (none) are tuned in three places. A change to retry policy (e.g. add a sleep between attempts, raise the count for flaky networks) must be made N times or it drifts. The two firewall fetches differ only in URL and the jq validation predicate yet share no code, making the script longer and the validation logic easy to get subtly inconsistent between them.
- **Recommendation:** Extract a `fetch_json_with_retry <url> <jq_validate_filter>` helper in init-firewall.sh that both call sites use, parameterizing only URL and predicate. Centralizes timeout/retry/backoff so policy changes are single-edit.

## Volume name-to-mountpoint map is duplicated between compose.yaml and a hardcoded heredoc in seed-claude.sh

- **Severity / kind:** low / docs
- **Location:** [.devcontainer/seed-claude.sh:81](.devcontainer/seed-claude.sh#L81)
- **Evidence:**
  > seed-claude.sh:82-85 hardcodes the mapping in the generated ENVIRONMENT.md ('/workspace -> claude-workspace', '/home/claude/.claude -> claude-config', '/commandhistory -> claude-bashhistory', '/home/claude/.local/share/pnpm -> claude-pnpm-store'). The authoritative definitions live in compose.yaml:34-93 (volume mounts + `name:` keys).
- **Why it matters:** ENVIRONMENT.md is regenerated every boot and is what Claude reads to learn the environment, so it presents as authoritative. If a volume is renamed, added (e.g. a new persistent path), or a mountpoint changes in compose.yaml, this hand-written list goes stale and actively misinforms — the one file claiming to be the 'live snapshot' is the one part that is NOT derived from anything live. It also silently omits the `claude-pgdata` volume entirely.
- **Recommendation:** Either generate this section from the actual mounts at runtime (e.g. parse `findmnt` / `mount` for the bind/volume targets inside the container) or drop the hardcoded table and point to `docker compose config`. If kept static, add a comment cross-linking compose.yaml so a renamer knows to update both.
