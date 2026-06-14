# firewall — audit findings

The firewall layer is functional in its common paths but carries one critical fail-open exposure and two confirmed (independently reported) high-severity bugs. The most serious issue is that `init-firewall.sh` runs under `set -euo pipefail` with no `trap` to fail closed, so any mid-script abort during the bootstrap window leaves `OUTPUT` policy at `ACCEPT` (unrestricted egress) on an already-running container — and the documented bare re-run paths have no retry wrapper to catch it. Separately, the AWS `@aws-ip-ranges <region>` narrowing feature loads zero CIDRs due to a `jq` indexing error, silently breaking AWS egress despite docs promising it "can't break login," and two unconditional egress allows (udp/53 and tcp/22 to any host) punch allowlist-bypassing exfil/tunnel channels through the default-deny posture. The remaining findings are medium-to-nit: a gitignored `COPY` source that breaks the documented raw `docker compose ... up --build` on a fresh clone, doc/code disagreement on the AWS region feature, lax `@aws*` directive matching, a missing completeness gate on the allowlist, and a fragile (but currently working) literal-IP case arm.

## Fail-OPEN window: mid-script abort under `set -e` leaves OUTPUT policy ACCEPT (no trap, no re-clamp on bare re-runs)

- **Severity / kind:** critical / security
- **Location:** [.devcontainer/init-firewall.sh:180](.devcontainer/init-firewall.sh#L180)
- **Evidence:**

  > Line 180: `iptables -P OUTPUT ACCEPT` ... ~120 lines later Line 300: `iptables -P OUTPUT DROP`. Between them: `ipset create allowed-domains hash:net` (202, no `|| true`), `echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat` (186, no `|| true`), `FW_IFACE="$(ip route | awk ...)"` (269, pipefail-sensitive), and many `iptables -A` calls. Script header is `set -euo pipefail` (15). `grep -nE '^\s*trap' init-firewall.sh` => no trap.

- **Why it matters:** The script opens egress fully (OUTPUT ACCEPT) early so it can fetch GitHub/AWS ranges, intending to clamp back to DROP at the very end. Because it runs `set -euo pipefail` with NO `trap ... ERR/EXIT` to fail closed, any non-zero command in that window aborts the script while OUTPUT is still ACCEPT = unrestricted egress. The entrypoint wraps the first apply in a 3x retry and exits 1 (container dies) on hard failure — contained. But CLAUDE.md explicitly documents bare re-runs with NO retry wrapper: in-container agents re-run `init-firewall.sh` to 'refresh rotated CDN IPs', `make firewall` (`docker exec claude-code sudo /usr/local/bin/init-firewall.sh`), and devcontainer.json `postStartCommand`. A single mid-script abort on any of those leaves the ALREADY-RUNNING container with OUTPUT=ACCEPT and nothing re-clamps it — the firewall silently fails open mid-session. Reproduced: `ip route` failing (pipefail) or any `iptables -t nat` xargs item failing aborts before the DROP clamp.
- **Recommendation:** Install a fail-closed guard immediately after line 180, before the open window: `trap 'iptables -P OUTPUT DROP 2>/dev/null || true; iptables -P INPUT DROP 2>/dev/null || true' EXIT` and clear it (`trap - EXIT`) only after the strict-mode DROP+REJECT rules are in place (and skip/relax it for the permissive branch). Alternatively, set OUTPUT policy to DROP first and add a temporary `-A OUTPUT -j ACCEPT` rule for the bootstrap, deleting that rule (not changing policy) at the end — so an abort never leaves the policy open.

## AWS region-filtered @aws-ip-ranges loads ZERO CIDRs (jq index(.region) rebinds '.' to the array)

- **Severity / kind:** high / bug
- **Location:** [.devcontainer/init-firewall.sh:149](.devcontainer/init-firewall.sh#L149)
- **Evidence:**

  > `jq_prog='.prefixes[] | select(.service=="AMAZON")\n                 | select((.region=="GLOBAL") or ($reg|index(.region)))\n                 | .ip_prefix'`  (line 158 pipes through `... | aggregate -q || true`)

- **Why it matters:** Inside `$reg|index(.region)` the leading `$reg|` rebinds jq's `.` to the $reg array, so `.region` evaluates as `["us-east-1"]["region"]` and jq dies with `Cannot index array with string "region"`. Reproduced deterministically (jq 1.6 in the bookworm image and jq 1.8.1 here both fail). Because the whole pipeline ends in `|| true` (line 158) and the loop reads from process substitution, the error is swallowed: count stays 0 and NO AWS CIDRs are added. Effect: any user who narrows by region — exactly the documented `@aws-ip-ranges us-east-1` form (extra-allowlist.txt.example:34, CLAUDE.md 'Optional region args narrow the set') — gets strict-mode egress with zero AWS prefixes, silently breaking `aws sso login`/STS/S3. The default no-region branch (line 152) uses a different jq_prog with no `$reg` and works, which is why this hid. The CLAUDE.md invariant claims region narrowing 'can't break login' (GLOBAL always kept) — but here it breaks login completely, so the doc is also wrong about this path.
- **Recommendation:** Bind the region before piping into the array, e.g. `select(.region=="GLOBAL" or (.region as $r | $reg|index($r)))` or `select(.region=="GLOBAL" or (.region | IN($reg[])))` — both verified to correctly keep GLOBAL + the requested region(s). Add a non-default-region smoke test to catch this. Optionally drop the blanket `|| true` on the jq stage (keep it only on `aggregate`) so a malformed jq program surfaces instead of failing closed to an empty set.

## AWS region-narrowing jq filter is broken — `@aws-ip-ranges <region>` loads ZERO CIDRs (including GLOBAL), silently killing AWS egress

- **Severity / kind:** high / bug
- **Location:** [.devcontainer/init-firewall.sh:148](.devcontainer/init-firewall.sh#L148)
- **Evidence:**

  > Lines 148-150: `jq_prog='.prefixes[] | select(.service=="AMAZON") | select((.region=="GLOBAL") or ($reg|index(.region))) | .ip_prefix'`. Reproduced with real ip-ranges shape: `echo '{"region":"us-east-1"}' | jq --argjson reg '["us-east-1"]' 'select(($reg|index(.region)))'` => `jq: error: Cannot index array with string "region"`.

- **Why it matters:** Inside `($reg | index(.region))`, the `.` refers to `$reg` (the array of region strings), so `.region` indexes the ARRAY, not the current prefix object. jq raises a hard error on EVERY prefix the moment a region filter is supplied, so the whole `.prefixes[] | ... | .ip_prefix` stream dies — including the GLOBAL/CloudFront prefixes. The error goes to stderr; `... | aggregate -q || true` (158) swallows the non-zero exit, the while-read loop gets zero lines, and the script logs `added 0 AWS CIDR(s)`. This directly contradicts CLAUDE.md ('Optional region args narrow the set (`@aws-ip-ranges us-east-1`); GLOBAL/CloudFront prefixes are always kept so narrowing can't break login') and extra-allowlist.txt.example line 34 ('GLOBAL/CloudFront always kept'). Any user who follows the documented narrowing syntax gets AWS egress completely broken (aws sso login + CLI fail), with only a misleading 'added 0' log. The default unfiltered path (line 152) is unaffected and works.
- **Recommendation:** Capture the prefix before the index: `'.prefixes[] | select(.service=="AMAZON") | . as $p | select($p.region=="GLOBAL" or ($reg|index($p.region))) | .ip_prefix'`. Add a non-empty-output assertion in add_aws_ranges (warn loudly if count==0 while a region filter was given) so this class of silent narrowing failure is visible.

## Unconditional udp/53 and tcp/22 ACCEPT to ANY host — allowlist-bypassing exfil/tunnel channels

- **Severity / kind:** high / security
- **Location:** [.devcontainer/init-firewall.sh:192](.devcontainer/init-firewall.sh#L192)
- **Evidence:**

  > Lines 192 & 194: `iptables -A OUTPUT -p udp --dport 53 -j ACCEPT` and `iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT`. These are appended to OUTPUT before the allowlist match (301) and final REJECT (302), with no destination scoping. `grep -niE 'port 22|port 53|exfil' CLAUDE.md` => not mentioned.

- **Why it matters:** In strict mode the OUTPUT chain evaluates these ACCEPTs first, so udp/53 to ANY resolver and tcp/22 to ANY host bypass the allowed-domains ipset entirely. udp/53-to-any is a classic data-exfiltration tunnel (DNS tunneling to an attacker-controlled authoritative server reachable on :53 — no allowlist entry needed). tcp/22-to-any allows an SSH/SCP tunnel to any internet host, defeating the default-deny posture for anything that can be funneled over SSH. The DNS rule only needs to reach the Docker embedded resolver (127.0.0.11) and/or whatever upstream that forwards to; the SSH rule is presumably for git-over-SSH but is not scoped to GitHub's published ranges (which the script already loads from /meta). For a sandbox whose entire purpose is constraining what an autonomous agent can reach, two wide-open egress ports are a material hole.
- **Recommendation:** Scope DNS to the resolver: `-A OUTPUT -p udp -d 127.0.0.11 --dport 53 -j ACCEPT` (plus the container CIDR / configured nameserver from /etc/resolv.conf) instead of `-j ACCEPT` to anywhere; add the matching tcp/53 for truncated answers if needed. Drop the blanket tcp/22 ACCEPT and rely on the allowed-domains ipset (GitHub ranges already loaded) for git-over-SSH, or gate the SSH allow behind FIREWALL_MODE/an explicit opt-in. At minimum, document these as deliberate bypass channels in CLAUDE.md.

## Dockerfile COPY of gitignored extra-allowlist.txt breaks the documented raw `docker compose ... up --build` on a fresh clone

- **Severity / kind:** medium / portability
- **Location:** [.devcontainer/Dockerfile:146](.devcontainer/Dockerfile#L146)
- **Evidence:**

  > Dockerfile line 146: `COPY config/extra-allowlist.txt /etc/claude-firewall/extra-allowlist.txt`. The file is gitignored (.gitignore:12 `.devcontainer/config/extra-allowlist.txt`); only `extra-allowlist.txt.example` is tracked (`git ls-files` confirms). The preflight `gen-allowlist.sh` runs ONLY from `make up`/`rebuild` and devcontainer `initializeCommand` — NOT from the raw command CLAUDE.md documents: `docker compose -f .devcontainer/compose.yaml up -d --build` (CLAUDE.md:25, compose.yaml:5).

- **Why it matters:** On a clean checkout the COPY source does not exist, so `docker build` fails at line 146 with 'failed to compute cache key: ... not found'. The CLI `make` path and VS Code path are covered by gen-allowlist, but the standalone `docker compose ... up -d --build` that CLAUDE.md presents as the primary build command (and that compose.yaml's own header documents) has no preflight and breaks for any new user who follows the README/quickstart literally. The local repo only builds today because the file was already generated on this machine.
- **Recommendation:** Either (a) make the Dockerfile resilient: `COPY config/extra-allowlist.txt* /etc/claude-firewall/` won't help since the basename differs — instead COPY the tracked `.example` and have entrypoint/init-firewall fall back to it when the bind-mount/real file is absent; or (b) COPY the `.example` to the in-image path and let the compose bind-mount override it at runtime (so a missing host file degrades to the template instead of failing the build); or (c) document that only `make up`/VS Code are supported and remove the raw `docker compose --build` from CLAUDE.md.

## extra-allowlist.txt.example documents @aws-ip-ranges region narrowing that is non-functional due to the jq bug

- **Severity / kind:** medium / docs
- **Location:** [.devcontainer/config/extra-allowlist.txt.example:34](.devcontainer/config/extra-allowlist.txt.example#L34)
- **Evidence:**

  > `# ... Optionally narrow by region to shrink the ipset, e.g. `@aws-ip-ranges us-east-1 eu-west-1` (GLOBAL/CloudFront always kept).`

- **Why it matters:** This template (and the parallel CLAUDE.md invariant: 'Optional region args narrow the set (@aws-ip-ranges us-east-1); GLOBAL/CloudFront prefixes are always kept so narrowing can't break login') advertises a feature that, per the confirmed jq finding above, loads ZERO CIDRs when any region is supplied. A user following the example to reduce ipset size would instead lose all AWS egress and, because it fails silently, would likely misdiagnose it as a different allowlist problem. This is the bidirectional-check failure: the doc/spec and code disagree, and the code is wrong.
- **Recommendation:** Fix the jq expression (primary finding), after which this doc becomes accurate. Until then, do not ship the region-narrowing example as 'safe'. After the fix, add a one-line note that region narrowing has been validated to retain GLOBAL prefixes.

## Typo'd `@aws...` directives silently route to the AWS branch and pass garbage as a region filter

- **Severity / kind:** medium / bug
- **Location:** [.devcontainer/init-firewall.sh:239](.devcontainer/init-firewall.sh#L239)
- **Evidence:**

  > Case arm `@aws*)` (239) then `regions="${line#@aws-ip-ranges}"; regions="${regions#@aws}"` (240). Reproduced: input `@awsfoo` -> regions=`foo`; input `@aws-something-typo` -> regions=`-something-typo`; input `@aws` -> regions=``. All match `@aws*` and invoke add_aws_ranges with a bogus region.

- **Why it matters:** The glob `@aws*` matches any line starting with `@aws`, not just the documented `@aws-ip-ranges`. A typo like `@aws-ipranges` or `@awsip-ranges` is accepted and treated as `@aws-ip-ranges <bogus-region>`. Combined with the region-filter bug above, this means a misspelled directive both (a) is NOT flagged as an unknown directive and (b) loads zero AWS CIDRs — a double-silent failure. There is no `@`-directive validation or 'unknown directive' warning; any other future `@foo` directive would fall through to the hostname/literal branches and be dig'd as a hostname.
- **Recommendation:** Match the directive exactly: `@aws-ip-ranges|@aws-ip-ranges\ *)` or test `case "$line" in '@aws-ip-ranges') ... ;; '@aws-ip-ranges '*) regions="${line#@aws-ip-ranges }"; ... ;; @*) warn "unknown @directive: ${line}" ;;`. Reject/warn on unrecognized `@` lines instead of treating any `@aws*` as the AWS feed.

## Strict-mode verify treats api.github.com as soft-warn but example.com block as fatal — a half-loaded allowed-domains set passes verification

- **Severity / kind:** low / test-gap
- **Location:** [.devcontainer/init-firewall.sh:322](.devcontainer/init-firewall.sh#L322)
- **Evidence:**

  > `if ! curl --connect-timeout 5 -fsS https://api.github.com/zen ...; then warn "api.github.com unreachable — GitHub ranges may have failed to load"`  (only a warn, not fatal)

- **Why it matters:** The only fatal post-check is the negative test (example.com must be blocked, line 316-319). Positive reachability of api.github.com is a non-fatal warn. Combined with the GitHub-meta fetch being non-fatal (line 220-222) and add_domain being non-fatal per-domain, a boot where api.github.com/meta AND the api.github.com A-record both fail leaves strict mode enforcing DROP with an essentially empty allowlist (only whatever resolved) — yet the script logs 'firewall configuration complete (strict)' and exits 0. The entrypoint's 3x retry (entrypoint.sh:17-27) only retries on non-zero exit, which this is not, so it won't re-attempt. This is by-design 'degrade, never brick' for egress availability, but there is no completeness gate: nothing asserts a minimum number of CIDRs landed in allowed-domains.
- **Recommendation:** Consider a soft completeness check: after building the set, `ipset list allowed-domains | wc -l` and warn loudly (or fail in a CI/strict-boot mode) if it is implausibly small (e.g. < N entries), so a totally-empty allowlist under strict DROP is visible rather than silently shipping a container that can reach nothing. Keep it a warn to preserve the no-brick invariant.

## Hostnames containing a digit.digit substring route through the literal-IP case arm before falling back to add_domain

- **Severity / kind:** nit / maintainability
- **Location:** [.devcontainer/init-firewall.sh:243](.devcontainer/init-firewall.sh#L243)
- **Evidence:**

  > `case "$line" in ... *[0-9].[0-9]*)`  # intended for literal IPv4/CIDR; matches any hostname with a digit-dot-digit, e.g. `s3.1.example.com` or `host1.2foo.net`

- **Why it matters:** The glob `*[0-9].[0-9]*` is meant to catch literal IPv4/CIDR lines, but it also matches legitimate hostnames that happen to contain a digit-dot-digit run. Such a hostname enters the literal arm, fails the strict regex guard `^[0-9.]+(/[0-9]{1,2})?$` (line 248), and correctly falls through to `add_domain "$cidr"` (line 254) — so it still works. Verified against all live allowlist entries (none currently trigger the misroute). It is fragile-by-construction, not currently broken: the fallthrough saves it. Worth a guard comment so the `continue` placement (only inside the regex-true branch) isn't 'tidied' into always-continue, which WOULD silently drop such hosts.
- **Recommendation:** No functional change required. Add an inline comment noting the fallthrough is load-bearing (a digit.digit hostname relies on reaching add_domain), or tighten the arm to anchor on a full-IP pattern (e.g. match only lines that are wholly `[0-9.]+(/[0-9]+)?`) so hostnames never enter it. Keep the existing regex guard either way.
