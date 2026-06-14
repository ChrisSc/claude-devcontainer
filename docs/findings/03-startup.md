# startup — audit findings

The startup orchestration is structurally sound — the entrypoint runs its steps in a load-bearing order and the firewall step is fatal — but two gaps undercut the boot guarantees. The most serious is that the firewall sandbox is IPv4-only, so on any IPv6-enabled Docker host the default-deny egress promise is silently bypassed. Secondarily, the primary `claude-code` container has no Docker healthcheck, so a container whose non-fatal boot steps (seed, update, cron) all failed still reports as "up" with no machine-checkable success signal. Neither is a hard crash, which is why both have gone unnoticed; both warrant remediation before the strict-mode containment claim can be trusted.

## Firewall step is IPv4-only: all IPv6 egress bypasses the allowlist

- **Severity / kind:** high / security
- **Location:** [.devcontainer/init-firewall.sh:300](.devcontainer/init-firewall.sh#L300)
- **Evidence:**

  `entrypoint.sh:22` runs `sudo FIREWALL_MODE=... /usr/local/bin/init-firewall.sh` as orchestrated step 1. That script configures only iptables (IPv4):

  ```
  iptables -P OUTPUT DROP
  iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT
  ```

  (lines 300-302). `grep -c ip6tables init-firewall.sh` = 0; the ipset is `hash:net` (IPv4-only, line 202). ip6tables OUTPUT default policy stays ACCEPT.

- **Why it matters:** The entrypoint's central promise is a default-deny egress sandbox, but it only governs IPv4. On any host where the Docker daemon has IPv6 enabled (default-on in newer Docker Engine builds; common on native Linux), the container gets a v6 address and every IPv6-reachable destination is fully reachable — an unrestricted data-exfiltration / arbitrary-fetch path that completely circumvents `allowed-domains`. Strict mode provides a false sense of containment.
- **Recommendation:** Mirror the IPv4 ruleset in ip6tables: in `firewall_supported` also probe `ip6tables`; restore/flush ip6tables; create an `ipset ... family inet6` for AAAA records (populate via `dig +short AAAA`); set `ip6tables -P OUTPUT DROP` with an allowed-domains-v6 ACCEPT + REJECT in strict mode. If full v6 support is out of scope, fail closed by setting `ip6tables -P OUTPUT DROP` (allowing only lo + DNS) so v6 egress is blocked outright rather than open.

## claude-code service has no Docker healthcheck — a container whose firewall/boot steps all failed still reports healthy/up

- **Severity / kind:** medium / bug
- **Location:** [.devcontainer/compose.yaml:11](.devcontainer/compose.yaml#L11)
- **Evidence:** The `db` service has a `healthcheck:` (lines 78-83) but the `claude-code` service (lines 11-42) has none; entrypoint steps 2-4 (seed, claude update, cron) are all `|| echo WARN ... (non-fatal)`.
- **Why it matters:** The firewall step is fatal (good), but seed-claude.sh, `claude update`, and init-cron.sh are deliberately non-fatal and only echo a WARN to stdout. With no healthcheck, `docker ps` / `make logs` / VS Code all show claude-code as 'Up' even if seeding failed (no CLAUDE.md/ENVIRONMENT.md), the auto-update failed, and cron never started. There is no machine-checkable boot-success signal anywhere — the operator must eyeball the log for WARN lines. This is the wiring-level analog of the observability findings already filed, but at the container-orchestration layer: the sidecar gets liveness, the primary container does not.
- **Recommendation:** Add a healthcheck to claude-code asserting the boot invariants (e.g. `command -v claude && [ -f ~/.claude/ENVIRONMENT.md ] && pgrep -x cron && iptables -S OUTPUT | grep -q DROP` in strict mode), so a half-booted container surfaces as unhealthy instead of silently 'up'.
