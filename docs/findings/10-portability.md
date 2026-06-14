# portability — audit findings

Overall, the area has one significant portability-driven security gap. The egress firewall is implemented entirely against the IPv4 stack, which means its strict default-deny guarantee is contingent on the host's Docker IPv6 configuration — a host-dependent variable. On an IPv6-enabled Docker host the sandbox's egress filtering is silently bypassed (or, depending on the verify gate, boot bricks). This is the single finding below and should be addressed to make the default-deny promise hold uniformly across host configurations.

## Egress firewall is IPv4-only — on an IPv6-enabled Docker host, strict-mode egress filtering is silently bypassed (or boot bricks at the verify gate)

- **Severity / kind:** high / security
- **Location:** [.devcontainer/init-firewall.sh:202](.devcontainer/init-firewall.sh#L202)
- **Evidence:**

  > Line 202 `ipset create allowed-domains hash:net` (defaults to family inet/IPv4); every rule uses `iptables` (IPv4) — there is no `ip6tables` anywhere in the repo (rg 'ip6tables' → NONE); line 106 resolves only `dig +short A` (no AAAA). No compose `enable_ipv6: false` and no `sysctl net.ipv6.conf.all.disable_ipv6` exist (rg over .devcontainer/ + compose.yaml → none).

- **Why it matters:** The strict firewall installs `iptables -P OUTPUT DROP` + an IPv4 allow-set, but never touches the IPv6 stack. Whether IPv6 is present is a host-dependent (portability) variable: stock Docker bridge has it off, but native-Linux daemons frequently enable it (`--ipv6` / `"ip6tables": true` in daemon.json) and Docker Desktop exposes an IPv6 toggle. On such a host, every destination with an AAAA record (github.com, pypi.org, api.anthropic.com, and arbitrary attacker hosts) is reachable over completely unfiltered IPv6 — the default-deny sandbox is defeated for any dual-stack peer. The CLAUDE.md promises strict default-deny egress; that guarantee silently does not hold on IPv6 hosts.
- **Recommendation:** Either (a) actively disable IPv6 in the container so there is one enforced stack — add `sysctls: [net.ipv6.conf.all.disable_ipv6=1, net.ipv6.conf.default.disable_ipv6=1]` to compose.yaml (and/or `enable_ipv6: false` on the network) — or (b) mirror the IPv4 logic with `ip6tables` + an `ipset ... family inet6` set populated from `dig +short AAAA`. Disabling IPv6 is the smaller, more robust change and matches the existing single-allowlist model.
