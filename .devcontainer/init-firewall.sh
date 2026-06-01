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

FIREWALL_MODE="${FIREWALL_MODE:-strict}"
EXTRA_ALLOWLIST="/etc/claude-firewall/extra-allowlist.txt"

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

# Resolve a domain and add every A record to the ipset. NON-FATAL by design.
add_domain() {
    local domain="$1" ips ip added=0
    ips="$(dig +short A "$domain" 2>/dev/null | grep -E '^[0-9.]+$' || true)"
    if [ -z "$ips" ]; then
        warn "could not resolve ${domain} — skipping (not fatal)"
        return 0
    fi
    while read -r ip; do
        [ -z "$ip" ] && continue
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
        jq_prog='.prefixes[] | select(.service=="AMAZON")
                 | select((.region=="GLOBAL") or ($reg|index(.region)))
                 | .ip_prefix'
    else
        jq_prog='.prefixes[] | select(.service=="AMAZON") | .ip_prefix'
    fi
    while read -r cidr; do
        [[ "$cidr" =~ ^[0-9.]+/[0-9]{1,2}$ ]] || continue
        ipset add allowed-domains "$cidr" 2>/dev/null && count=$((count + 1))
    done < <(echo "$json" \
        | jq -r --argjson reg "$reg_json" "$jq_prog" | aggregate -q || true)
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

# CRITICAL: `iptables -F` flushes rules but NOT the default policy. On a re-run,
# the leftover OUTPUT=DROP from the previous invocation would block the bootstrap
# GitHub-meta fetch below (DNS resolves, but the :443 connect is dropped). Reset
# policies to ACCEPT during reconfiguration; they're clamped back to DROP at the
# end (strict mode). Brief open window is acceptable — root is reconfiguring its
# own egress and the script ends in default-deny.
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

if [ -n "$DOCKER_DNS_RULES" ]; then
    log "restoring Docker DNS NAT rules"
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
fi

# ---------------------------------------------------------------------------
# 2. Baseline allows (DNS / SSH / loopback) before any restriction
# ---------------------------------------------------------------------------
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT  -p udp --sport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT  -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

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
            @aws*)
                regions="${line#@aws-ip-ranges}"; regions="${regions#@aws}"
                add_aws_ranges "$regions"
                ;;
            *[0-9].[0-9]*)
                # Literal IPv4 address or CIDR (e.g. a LAN host / static IP).
                # add_domain can't handle these — dig would treat the IP as a
                # hostname and resolve nothing. Add straight to the ipset.
                cidr="$(echo "$line" | tr -d '[:space:]')"
                if [[ "$cidr" =~ ^[0-9.]+(/[0-9]{1,2})?$ ]]; then
                    if ipset add allowed-domains "$cidr" 2>/dev/null; then
                        log "added literal ${cidr}"
                    fi
                    continue
                fi
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

case "$FIREWALL_MODE" in
    permissive|dev)
        echo
        echo "  ############################################################"
        echo "  #  FIREWALL_MODE=${FIREWALL_MODE} — OUTBOUND EGRESS IS UNRESTRICTED  #"
        echo "  #  WebFetch/WebSearch and arbitrary curl will work.        #"
        echo "  ############################################################"
        echo
        iptables -P OUTPUT ACCEPT
        log "firewall configuration complete (permissive)"
        exit 0
        ;;
    strict)
        iptables -P OUTPUT DROP
        iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT
        iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited
        ;;
    *)
        warn "unknown FIREWALL_MODE='${FIREWALL_MODE}', defaulting to strict"
        iptables -P OUTPUT DROP
        iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT
        iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited
        ;;
esac

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
