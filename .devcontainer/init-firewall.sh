#!/bin/bash
#
# init-firewall.sh — layered default-deny egress firewall for the Claude sandbox.
#
# Derived from the official anthropics/claude-code init-firewall.sh, with:
#   * an expanded allowlist (Claude auth/update, PyPI, uv, GitHub release assets,
#     Playwright CDN, ...) — see ALLOWED_DOMAINS below;
#   * a NON-FATAL per-domain resolver (the upstream script exit 1's when a domain
#     fails to resolve; statsig.anthropic.com has no public A record and bricks
#     startup — see anthropics/claude-code#55623);
#   * a host-editable extra allowlist at /etc/claude-firewall/extra-allowlist.txt;
#   * a FIREWALL_MODE switch: strict (default) | permissive|dev.
#
# Invoked at startup via sudo (entrypoint.sh + devcontainer postStartCommand).
set -euo pipefail
IFS=$'\n\t'

# The mode is STICKY across re-runs. The entrypoint / postStartCommand pass
# FIREWALL_MODE explicitly (sudoers env_reset would strip the ambient var) and
# it is recorded in MODE_FILE; a BARE `sudo init-firewall.sh` re-run — e.g. an
# in-container agent refreshing rotated CDN IPs, or `make firewall` — re-reads
# the recorded mode instead of silently clamping a permissive container back to
# strict. Precedence: explicit env > recorded mode > strict.
MODE_FILE="/etc/claude-firewall/mode"
if [ -z "${FIREWALL_MODE:-}" ] && [ -r "$MODE_FILE" ]; then
    FIREWALL_MODE="$(head -n1 "$MODE_FILE" | tr -d '[:space:]')"
fi
FIREWALL_MODE="${FIREWALL_MODE:-strict}"
EXTRA_ALLOWLIST="/etc/claude-firewall/extra-allowlist.txt"
# Resilience for a raw `docker compose up --build` on a fresh clone: if the real
# allowlist is absent (gen-allowlist.sh hasn't run, or the bind-mount source was
# missing so Docker created an empty dir there), fall back to the baked tracked
# template so the firewall still has a sane allowlist instead of breaking.
EXTRA_ALLOWLIST_FALLBACK="/etc/claude-firewall/extra-allowlist.txt.example"
if [ ! -f "$EXTRA_ALLOWLIST" ] && [ -f "$EXTRA_ALLOWLIST_FALLBACK" ]; then
    EXTRA_ALLOWLIST="$EXTRA_ALLOWLIST_FALLBACK"
fi

# Always-on allowlist. Build-time installs are unaffected (they precede the
# firewall); these are the hosts needed at RUNTIME.
ALLOWED_DOMAINS=(
    # --- Claude Code runtime + auth + auto-update ---
    api.anthropic.com                       # Claude API + WebFetch preflight
    claude.ai                               # claude.ai OAuth login; install.sh origin
    platform.claude.com                     # Anthropic Console account auth
    downloads.claude.ai                     # native installer + auto-updater; plugins
    storage.googleapis.com                  # legacy updater (<2.1.116) — transitional
    raw.githubusercontent.com               # /release-notes feed + raw fetches
    statsig.anthropic.com                   # telemetry (may NOT resolve — non-fatal)
    statsig.com                             # telemetry fallback
    sentry.io                               # crash reporting
    # --- Node / JS ---
    registry.npmjs.org                      # npm + pnpm + pnpm self-update
    # --- Python (uv / pip) ---
    pypi.org                                # index
    files.pythonhosted.org                  # wheels / sdists
    astral.sh                               # uv self-update
    # --- GitHub web/API/assets (explicit fallback if api.github.com/meta ---
    # --- ranges flake at boot; also covers the OAuth device-flow host) ---
    github.com                              # git over HTTPS + login/device OAuth flow
    api.github.com                          # gh API (also in meta ranges)
    objects.githubusercontent.com           # release assets (uv pythons, gh, ...)
    codeload.github.com                     # tarball / zipball downloads
    # --- Playwright browser downloads (browsers are baked; this is a fallback) ---
    cdn.playwright.dev
    playwright.download.prss.microsoft.com
    # --- VS Code ---
    marketplace.visualstudio.com
    vscode.blob.core.windows.net
    update.code.visualstudio.com
)

log()  { echo "[firewall] $*"; }
warn() { echo "[firewall] WARN: $*" >&2; }

# Strict IPv4 / IPv4-CIDR validator. The loose `^[0-9.]+$` guard this replaces
# admitted malformed addresses (`999.999.0.0`, `1.2.3`, `1...1`) that `ipset add`
# then silently rejected. Per-octet 0-255, optional `/0-32` prefix.
IPV4_OCTET='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
IPV4_RE="^${IPV4_OCTET}\.${IPV4_OCTET}\.${IPV4_OCTET}\.${IPV4_OCTET}(/(3[0-2]|[12]?[0-9]))?$"
is_ipv4_cidr() { [[ "$1" =~ $IPV4_RE ]]; }

# ---------------------------------------------------------------------------
# 0. Kernel-capability preflight (portability: some WSL2 kernels lack the
#    netfilter / ip_set modules this script needs). Probe BEFORE flushing, so a
#    capability gap can't leave the box in a half-configured state. If the kernel
#    can't support the firewall, DEGRADE: warn loudly and exit 0 with egress
#    OPEN, rather than bricking startup. On Apple Silicon / WSL2-backend Docker
#    this passes; it only trips on limited/custom kernels.
# ---------------------------------------------------------------------------
firewall_supported() {
    command -v iptables >/dev/null 2>&1 || return 1
    command -v ipset    >/dev/null 2>&1 || return 1
    iptables -t filter -S >/dev/null 2>&1 || return 1   # netfilter present?
    if ! ipset create __fw_probe hash:net 2>/dev/null; then
        return 1                                         # ip_set module present?
    fi
    ipset destroy __fw_probe 2>/dev/null || true
    return 0
}

# Probe the IPv6 stack separately. The egress filter must cover BOTH families or
# strict default-deny is silently bypassed over IPv6 on a dual-stack host. If
# ip6tables is usable we mirror the v4 ruleset (fail-closed: DROP + allow only
# lo/DNS/loaded sets); if the v6 module is absent we treat IPv6 as unavailable
# (nothing to filter). Non-fatal either way — a v6 gap must never brick boot.
ip6tables_supported() {
    command -v ip6tables >/dev/null 2>&1 || return 1
    ip6tables -t filter -S >/dev/null 2>&1 || return 1
    return 0
}

if ! firewall_supported; then
    echo
    echo "  ############################################################"
    echo "  #  FIREWALL DEGRADED — kernel lacks iptables/ipset support  #"
    echo "  #  Egress is UNFILTERED. On Windows, ensure Docker uses the #"
    echo "  #  WSL2 backend (not Hyper-V). The container still runs.    #"
    echo "  ############################################################"
    echo
    warn "skipping firewall setup; outbound traffic is NOT restricted"
    exit 0
fi

# Serialize overlapping invocations (boot entrypoint vs. `make firewall` /
# devcontainer postStartCommand). The script mutates kernel-global singletons by
# fixed name (the allowed-domains ipset, the OUTPUT policy, the mode file); two
# runs racing can leave a half-filled set or egress wide open. flock on a fixed
# path makes them run one-at-a-time. Held for the whole reconfiguration; released
# automatically when the script exits (fd 9 closes).
exec 9>/run/claude-firewall.lock
flock 9

# Is the IPv6 stack present and filterable? Captured once; gates every ip6tables
# block below so a v6-less kernel is a clean no-op (never a hard error).
if ip6tables_supported; then
    HAVE_IP6=1
else
    HAVE_IP6=0
    warn "ip6tables unavailable — IPv6 stack not present; v6 egress not filtered"
fi

# Record the effective mode so later bare re-runs inherit it (see MODE_FILE above).
mkdir -p "$(dirname "$MODE_FILE")"
printf '%s\n' "$FIREWALL_MODE" > "$MODE_FILE"

# Resolve a domain and add every A record to the ipset. NON-FATAL by design.
add_domain() {
    local domain="$1" ips ip added=0
    ips="$(dig +short A "$domain" 2>/dev/null || true)"
    if [ -z "$ips" ]; then
        warn "could not resolve ${domain} — skipping (not fatal)"
        return 0
    fi
    while read -r ip; do
        [ -z "$ip" ] && continue
        # dig can emit CNAME chains / odd lines; only feed real IPv4 addrs.
        is_ipv4_cidr "$ip" || continue
        if ipset add allowed-domains "$ip" 2>/dev/null; then
            added=$((added + 1))
        fi
    done <<< "$ips"
    log "added ${added} IP(s) for ${domain}"
}

# Load AWS's published CIDR ranges (ip-ranges.json) into the ipset. This is the
# AWS analog of GitHub's /meta feed: apex A-record pinning (add_domain) can NOT
# cover AWS, whose endpoints are wildcard, per-region, and CloudFront-fronted
# (oidc/portal.sso/sts/s3.<region>.amazonaws.com, <id>.awsapps.com, ...). A bare
# `amazonaws.com` has no useful A record; the few that resolve are CloudFront and
# go stale. So we allow the published prefixes instead. NON-FATAL by design.
#
# Hardcoded to service "AMAZON" — the superset that subsumes S3/EC2/CLOUDFRONT/
# the SSO+STS endpoints needed for `aws sso login` + CLI. Optional region filter
# (space/comma-separated) shrinks the set massively; GLOBAL prefixes (CloudFront,
# awsapps.com assets) are ALWAYS kept so narrowing by region can't break login.
add_aws_ranges() {
    local region_filter="${1:-}" json="" count=0 cidr reg_json='[]' jq_prog
    log "fetching AWS IP ranges (service=AMAZON, regions=${region_filter:-all})"
    for attempt in 1 2 3; do
        json="$(curl -fsSL --connect-timeout 5 \
            https://ip-ranges.amazonaws.com/ip-ranges.json || true)"
        [ -n "$json" ] && echo "$json" | jq -e '.prefixes' >/dev/null 2>&1 && break
        warn "AWS ip-ranges fetch attempt ${attempt} failed; retrying"
        json=""
    done
    if [ -z "$json" ]; then
        warn "AWS ip-ranges unavailable — AWS access may be limited"
        return 0
    fi
    if [ -n "$region_filter" ]; then
        reg_json="$(printf '%s' "$region_filter" | tr ', ' '\n\n' \
            | grep -v '^$' | jq -R . | jq -s .)"
        # Capture the prefix object as $p BEFORE piping into the region array.
        # The naive `($reg|index(.region))` rebinds `.` to $reg inside index(),
        # so `.region` is read off the array (-> error / zero matches) and the
        # filter silently drops EVERYTHING, GLOBAL included. Binding $p first
        # keeps `.region` referring to the prefix. GLOBAL is always retained.
        jq_prog='.prefixes[] | select(.service=="AMAZON") | . as $p
                 | select($p.region=="GLOBAL" or ($reg|index($p.region)))
                 | .ip_prefix'
    else
        jq_prog='.prefixes[] | select(.service=="AMAZON") | .ip_prefix'
    fi
    # No blanket `|| true` on the jq stage: a malformed jq program must surface
    # (a non-zero exit ends the pipeline) rather than failing closed to an empty
    # set. `aggregate` keeps its `|| true` (best-effort coalescing).
    while read -r cidr; do
        is_ipv4_cidr "$cidr" || continue
        ipset add allowed-domains "$cidr" 2>/dev/null && count=$((count + 1))
    done < <(echo "$json" \
        | jq -r --argjson reg "$reg_json" "$jq_prog" | { aggregate -q || true; })
    # A region filter that yields zero CIDRs is almost always the silent-narrowing
    # bug above, not a legitimately empty region — warn loudly so it's visible.
    if [ -n "$region_filter" ] && [ "$count" -eq 0 ]; then
        warn "AWS region filter '${region_filter}' matched ZERO CIDRs — check the region name(s); AWS egress will be broken"
    fi
    log "added ${count} AWS CIDR(s)"
}

# ---------------------------------------------------------------------------
# 1. Preserve Docker's internal DNS NAT rules across the flush
# ---------------------------------------------------------------------------
DOCKER_DNS_RULES="$(iptables-save -t nat | grep '127\.0\.0\.11' || true)"

iptables -F; iptables -X
iptables -t nat -F; iptables -t nat -X
iptables -t mangle -F; iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# Flush the IPv6 stack too. Without this, a leftover v6 ruleset from a prior run
# (or a host that pre-populated ip6tables) would coexist with — and could
# override — the policy we set below.
if [ "$HAVE_IP6" = "1" ]; then
    ip6tables -F; ip6tables -X
    ip6tables -t mangle -F 2>/dev/null || true
    ip6tables -t mangle -X 2>/dev/null || true
fi

# CRITICAL: `iptables -F` flushes rules but NOT the default policy. On a re-run,
# the leftover OUTPUT=DROP from the previous invocation would block the bootstrap
# GitHub-meta fetch below (DNS resolves, but the :443 connect is dropped). Reset
# policies to ACCEPT during reconfiguration; they're clamped back to DROP at the
# end (strict mode). Brief open window is acceptable — root is reconfiguring its
# own egress and the script ends in default-deny.
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# FAIL-CLOSED GUARD. The open window above (and the IPv6 reset below) leaves
# OUTPUT=ACCEPT while the allowlist is being rebuilt. Under `set -e`, any command
# failing mid-script (a flaky `ip`/`ipset`/`iptables` call, a killed run) would
# abort with egress still OPEN. This trap re-clamps OUTPUT (and INPUT) to DROP on
# ANY exit before the final ruleset is committed; it is cleared (`trap - EXIT`)
# only after strict-mode DROP+REJECT is in place, and relaxed for the permissive
# branch (which deliberately ends OUTPUT=ACCEPT). v6 may be absent — non-fatal.
trap 'iptables -P OUTPUT DROP 2>/dev/null || true
      iptables -P INPUT DROP 2>/dev/null || true
      ip6tables -P OUTPUT DROP 2>/dev/null || true
      ip6tables -P INPUT DROP 2>/dev/null || true' EXIT

# Same ACCEPT-during-reconfigure reset for IPv6; clamped to DROP at the end.
if [ "$HAVE_IP6" = "1" ]; then
    ip6tables -P INPUT ACCEPT
    ip6tables -P FORWARD ACCEPT
    ip6tables -P OUTPUT ACCEPT
fi

if [ -n "$DOCKER_DNS_RULES" ]; then
    log "restoring Docker DNS NAT rules"
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
fi

# ---------------------------------------------------------------------------
# 2. Baseline allows (DNS / loopback) before any restriction
# ---------------------------------------------------------------------------
# DNS is SCOPED to the configured resolver(s), NOT a blanket any-destination
# ACCEPT. An unrestricted udp/53 (and tcp/53) to ANY host is a textbook
# DNS-tunneling exfil channel that bypasses the allowed-domains ipset entirely.
# We allow udp+tcp/53 only to the nameservers in /etc/resolv.conf (Docker's
# embedded resolver is 127.0.0.11; a custom DNS may be a LAN/public IP). tcp/53
# covers truncated answers. Resolution against any other destination is dropped.
DNS_SERVERS="$(awk '/^nameserver/ {print $2}' /etc/resolv.conf 2>/dev/null || true)"
if [ -z "$DNS_SERVERS" ]; then
    # Fall back to Docker's embedded resolver if resolv.conf yielded nothing —
    # never leave DNS fully open as a fallback.
    DNS_SERVERS="127.0.0.11"
    warn "no nameserver in /etc/resolv.conf — scoping DNS to 127.0.0.11 only"
fi
while read -r dns; do
    is_ipv4_cidr "$dns" || continue
    iptables -A OUTPUT -p udp -d "$dns" --dport 53 -j ACCEPT
    iptables -A OUTPUT -p tcp -d "$dns" --dport 53 -j ACCEPT
    log "DNS egress allowed to ${dns}"
done <<< "$DNS_SERVERS"
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
# NOTE: there is intentionally no blanket tcp/22 (SSH) allow. git-over-SSH to
# github.com is covered by the allowed-domains ipset (the meta CIDRs + the
# pinned github.com A records) via the generic OUTPUT match-set rule in strict
# mode. An unconditional --dport 22 ACCEPT to any host is an allowlist-bypassing
# tunnel/exfil channel, so SSH rides the same allowlist as everything else.

# IPv6 baseline: loopback + (scoped) DNS only. We do NOT mirror the v4 allowlist
# over v6 (no AAAA ipset); the v6 stack fails CLOSED (DROP + REJECT below) so no
# destination bypasses the v4 allowlist over IPv6. DNS is scoped to any IPv6
# nameserver(s) in /etc/resolv.conf — NOT a blanket any-destination allow (same
# DNS-tunneling concern as v4). Docker's embedded resolver is v4 (127.0.0.11),
# so typically there are no v6 nameservers and only loopback is opened here.
# Don't relax this to a blanket ACCEPT.
if [ "$HAVE_IP6" = "1" ]; then
    DNS6_SERVERS="$(awk '/^nameserver/ && $2 ~ /:/ {print $2}' \
        /etc/resolv.conf 2>/dev/null || true)"
    while read -r dns6; do
        [ -z "$dns6" ] && continue
        ip6tables -A OUTPUT -p udp -d "$dns6" --dport 53 -j ACCEPT
        ip6tables -A OUTPUT -p tcp -d "$dns6" --dport 53 -j ACCEPT
        log "DNS egress (v6) allowed to ${dns6}"
    done <<< "$DNS6_SERVERS"
    ip6tables -A INPUT  -i lo -j ACCEPT
    ip6tables -A OUTPUT -o lo -j ACCEPT
fi

# ---------------------------------------------------------------------------
# 3. Build the allowed-domains ipset
# ---------------------------------------------------------------------------
ipset create allowed-domains hash:net

# GitHub IP ranges from the meta API (web + api + git), aggregated. Retried,
# then non-fatal (git/gh will be impaired but the box still boots).
log "fetching GitHub IP ranges"
gh_ranges=""
for attempt in 1 2 3; do
    gh_ranges="$(curl -fsSL --connect-timeout 5 https://api.github.com/meta || true)"
    [ -n "$gh_ranges" ] && echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null 2>&1 && break
    warn "GitHub meta fetch attempt ${attempt} failed; retrying"
    gh_ranges=""
done
if [ -n "$gh_ranges" ]; then
    while read -r cidr; do
        [[ "$cidr" =~ ^[0-9.]+/[0-9]{1,2}$ ]] || continue
        ipset add allowed-domains "$cidr" 2>/dev/null || true
    done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q || true)
    log "added GitHub meta ranges"
else
    warn "GitHub meta ranges unavailable — github.com access may be limited"
fi

# Hardcoded allowlist.
for domain in "${ALLOWED_DOMAINS[@]}"; do
    add_domain "$domain"
done

# Host-editable extra allowlist (one hostname per line, '#' comments). A line of
# the form `@aws-ip-ranges [region ...]` loads AWS's published CIDRs instead of
# pinning apex IPs (see add_aws_ranges) — needed for `aws sso login` + the CLI.
if [ -f "$EXTRA_ALLOWLIST" ]; then
    log "processing extra allowlist ${EXTRA_ALLOWLIST}"
    while IFS= read -r line; do
        line="${line%%#*}"
        line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -z "$line" ] && continue
        case "$line" in
            @aws-ip-ranges)
                # Bare directive: load ALL AMAZON prefixes (no region filter).
                add_aws_ranges ""
                ;;
            '@aws-ip-ranges '*)
                # Region-narrowed: everything after the directive is the filter.
                regions="${line#@aws-ip-ranges }"
                add_aws_ranges "$regions"
                ;;
            @*)
                # An unrecognized @-directive (typo, future feature). Don't fall
                # through to the AWS branch with garbage as a region filter —
                # warn and skip so the mistake is visible, not silently absorbed.
                warn "unknown @directive: '${line}' — skipping"
                ;;
            *[0-9].[0-9]*)
                # Literal IPv4 address or CIDR (e.g. a LAN host / static IP).
                # add_domain can't handle these — dig would treat the IP as a
                # hostname and resolve nothing. Add straight to the ipset.
                cidr="$(echo "$line" | tr -d '[:space:]')"
                if is_ipv4_cidr "$cidr"; then
                    # Operator-supplied literal: surface failures instead of
                    # swallowing them. ipset returns 1 for BOTH a duplicate and a
                    # rejected value; inspect stderr to tell them apart so a typo
                    # doesn't pass silently as a no-op.
                    if add_err="$(ipset add allowed-domains "$cidr" 2>&1)"; then
                        log "added literal ${cidr}"
                    elif [[ "$add_err" == *"already added"* ]]; then
                        log "literal ${cidr} already present (ok)"
                    else
                        warn "ipset rejected literal ${cidr}: ${add_err}"
                    fi
                    continue
                fi
                # Looks numeric-ish but isn't a valid IPv4/CIDR (e.g. a typo or a
                # hostname containing digits). Surface it, then try DNS.
                warn "extra-allowlist entry '${cidr}' is not a valid IPv4/CIDR; treating as hostname"
                add_domain "$cidr"
                ;;
            *)
                add_domain "$(echo "$line" | tr -d '[:space:]')"
                ;;
        esac
    done < "$EXTRA_ALLOWLIST"
fi

# Allow the host /24 (so host-side tooling / port-forwards work).
# Allow the container's OWN Docker subnet so peer containers (the db sidecar,
# any future sidecar) and the gateway are reachable. Use the REAL prefix from the
# interface — NOT a guessed /24. The compose network is a /16; a sidecar that
# lands at 172.x.1.y is outside a /24 and would die with `no route to host`.
# iptables masks the address to the network, so a host-bit CIDR is fine.
FW_IFACE="$(ip route | awk '/default/ {print $5; exit}')"
CONTAINER_CIDR="$(ip -o -f inet addr show "${FW_IFACE:-eth0}" 2>/dev/null | awk '{print $4; exit}')"
if [ -n "${CONTAINER_CIDR:-}" ]; then
    log "container subnet ${CONTAINER_CIDR}"
    iptables -A INPUT  -s "$CONTAINER_CIDR" -j ACCEPT
    iptables -A OUTPUT -d "$CONTAINER_CIDR" -j ACCEPT
else
    warn "could not detect container subnet"
fi

# ---------------------------------------------------------------------------
# 4. Policies + egress decision (depends on FIREWALL_MODE)
# ---------------------------------------------------------------------------
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

if [ "$HAVE_IP6" = "1" ]; then
    ip6tables -P INPUT DROP
    ip6tables -P FORWARD DROP
    ip6tables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
fi

case "$FIREWALL_MODE" in
    permissive|dev)
        echo
        echo "  ############################################################"
        echo "  #  FIREWALL_MODE=${FIREWALL_MODE} — OUTBOUND EGRESS IS UNRESTRICTED  #"
        echo "  #  WebFetch/WebSearch and arbitrary curl will work.        #"
        echo "  ############################################################"
        echo
        iptables -P OUTPUT ACCEPT
        if [ "$HAVE_IP6" = "1" ]; then
            ip6tables -P OUTPUT ACCEPT
        fi
        # Permissive deliberately ends with OUTPUT OPEN — drop the fail-closed
        # guard so it doesn't re-clamp to DROP on the exit below.
        trap - EXIT
        log "firewall configuration complete (permissive)"
        exit 0
        ;;
    strict)
        iptables -P OUTPUT DROP
        iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT
        iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited
        # IPv6 fails closed: no v6 allowlist, so DROP + REJECT everything past
        # the loopback/DNS baseline. No v6 destination bypasses the v4 allowlist.
        if [ "$HAVE_IP6" = "1" ]; then
            ip6tables -P OUTPUT DROP
            ip6tables -A OUTPUT -j REJECT --reject-with icmp6-adm-prohibited
        fi
        ;;
    *)
        warn "unknown FIREWALL_MODE='${FIREWALL_MODE}', defaulting to strict"
        iptables -P OUTPUT DROP
        iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT
        iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited
        if [ "$HAVE_IP6" = "1" ]; then
            ip6tables -P OUTPUT DROP
            ip6tables -A OUTPUT -j REJECT --reject-with icmp6-adm-prohibited
        fi
        ;;
esac

# Strict ruleset (v4 DROP+REJECT, v6 fail-closed) is now committed — release the
# fail-closed guard so the verify step's deliberate failures don't trip it.
trap - EXIT

# ---------------------------------------------------------------------------
# 5. Verify (strict mode). Negative test is security-critical -> fatal.
# ---------------------------------------------------------------------------
log "verifying firewall"
if curl --connect-timeout 5 -fsS https://example.com >/dev/null 2>&1; then
    echo "[firewall] ERROR: example.com reachable — DROP not enforced" >&2
    exit 1
fi
log "verified: example.com is blocked"

if ! curl --connect-timeout 5 -fsS https://api.github.com/zen >/dev/null 2>&1; then
    warn "api.github.com unreachable — GitHub ranges may have failed to load"
else
    log "verified: api.github.com is reachable"
fi

log "firewall configuration complete (strict)"
