# security-hardening — audit findings

Overall the container's security posture is solid — strict default-deny egress, a dropped/renamed unprivileged user, opt-in DB sidecar, and a firewall that degrades rather than bricks — but the hardening leaves recoverable gaps at the edges. Two medium findings weaken the runtime threat model: an unused `NET_RAW` capability that hands a compromised process raw/packet-socket primitives for free, and strict-mode firewall holes that allow DNS (udp/53) and SSH (tcp/22) egress to *any* host, undercutting the exfiltration guardrail the project advertises. The three low findings are all supply-chain reproducibility/integrity gaps in the build path — floating tool versions, tag-pinned (not digest-pinned) base images, and release binaries fetched with no checksum or signature verification — each of which turns a future upstream compromise into an automatic, unreviewed inclusion in a root-built image. None are live exploits today; all are defense-in-depth tightening appropriate for an image whose entire value proposition is being a security sandbox.

## NET_RAW capability is granted but never used — drop it

- **Severity / kind:** medium / security
- **Location:** [`.devcontainer/compose.yaml:21`](.devcontainer/compose.yaml#L21)
- **Evidence:**

  ```yaml
  cap_add:
    - NET_ADMIN
    - NET_RAW   # compose.yaml:19-21. init-firewall.sh uses only iptables/ipset (no raw sockets, no -p icmp, no ping/traceroute).
  ```

  A grep for `icmp|raw|ping` in `init-firewall.sh` finds only the REJECT `--reject-with icmp-admin-prohibited` (a netfilter target, not a raw socket).
- **Why it matters:** The egress firewall needs `NET_ADMIN` to manage iptables/ipset, but it never opens an AF_PACKET/AF_INET raw socket, so `NET_RAW` grants nothing the container uses. `NET_RAW` is a meaningful capability to withhold: it enables raw/packet sockets usable for ARP/DNS spoofing on the Docker bridge, ICMP-tunnel exfiltration, and crafted-packet attacks against sidecars (the db) — capabilities a compromised dependency or misbehaving agent would otherwise gain for free. CLAUDE.md's "Required for the iptables/ipset egress firewall" comment and SECURITY.md:25 both bundle `NET_RAW` with `NET_ADMIN`, but only `NET_ADMIN` is actually load-bearing.
- **Recommendation:** Remove the `- NET_RAW` line from `cap_add` in `.devcontainer/compose.yaml` (keep `NET_ADMIN`). Boot with `make up` and run `make firewall` to confirm iptables/ipset still apply and `make doctor`/egress still works (they will — the firewall path uses no raw sockets). Update the `cap_add` comment and SECURITY.md:25 to stop listing `NET_RAW`. If a future need for raw ICMP (e.g. in-container `ping` diagnostics) appears, re-add it deliberately with a comment.

## Strict firewall leaks DNS (udp/53) and SSH (tcp/22) egress to ANY host

- **Severity / kind:** medium / security
- **Location:** [`.devcontainer/init-firewall.sh:192`](.devcontainer/init-firewall.sh#L192)
- **Evidence:**

  ```
  iptables -A OUTPUT -p udp --dport 53 -j ACCEPT  (line 192)
  iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT  (line 194)
  ```

  These are added before the OUTPUT DROP policy and have no destination match, so in strict mode the container can still reach 53/udp and 22/tcp on ANY IP, bypassing the allowed-domains ipset.
- **Why it matters:** The whole point of strict mode is default-deny egress to limit exfiltration. But unrestricted udp/53 to any host is a classic DNS-tunnel exfiltration channel (data encoded into queries to an attacker-controlled authoritative server) that the allowlist does not constrain. Container DNS already goes through Docker's embedded resolver at 127.0.0.11 (the script preserves those NAT rules, init-firewall.sh:165/184), so applications never need to talk port 53 to an arbitrary external IP directly. Likewise tcp/22 to any host lets a compromised process open an outbound SSH/SFTP tunnel to an arbitrary server even though only github.com's SSH endpoints are intended. The README/SECURITY.md sell strict mode as the exfiltration guardrail; these two any-destination holes quietly weaken it.
- **Recommendation:** In `.devcontainer/init-firewall.sh`, scope these baseline allows. For DNS, restrict to Docker's embedded resolver: `iptables -A OUTPUT -p udp -d 127.0.0.11 --dport 53 -j ACCEPT` (and tcp/53 to 127.0.0.11 for large responses) instead of the any-destination rule; the existing NAT keeps 127.0.0.11 working. For SSH, either drop the blanket `--dport 22` rule (git-over-SSH to github.com is already covered by the github.com/meta CIDRs in the allowed-domains set on tcp/443 and 22) or gate it behind the allowed-domains ipset: `iptables -A OUTPUT -p tcp --dport 22 -m set --match-set allowed-domains dst -j ACCEPT`. Verify `ssh -T git@github.com` and `dig` still work after the change. Add a comment noting strict mode now also constrains 53/22.

## Floating versions for build-time toolchain (pnpm@latest, global npm tools, uv-managed Python/ruff)

- **Severity / kind:** low / maintainability
- **Location:** [`.devcontainer/Dockerfile:100`](.devcontainer/Dockerfile#L100)
- **Evidence:**

  ```
  corepack prepare pnpm@latest --activate (Dockerfile:100)
  npm install -g typescript tsx eslint prettier pyright playwright (Dockerfile:101, no versions)
  uv tool install ruff (Dockerfile:204, no version)
  uv python install 3.14 (minor pin only)
  ```

  yq/lazygit also resolve `releases/latest` (install-tools.sh:41,46).
- **Why it matters:** `@latest`/unversioned installs make the image non-reproducible: two rebuilds days apart yield different pnpm, eslint, prettier, playwright, ruff, etc. Beyond reproducibility, floating versions are a supply-chain risk multiplier — a malicious or trojaned release of any of these popular packages (npm/PyPI account takeovers happen) gets pulled automatically on the next `make rebuild` with no review gate, and lands as root in the image. Pinning turns an automatic compromise into a deliberate, reviewable bump.
- **Recommendation:** Pin explicit versions for the build-time toolchain in `.devcontainer/Dockerfile`: `corepack prepare pnpm@<x.y.z>`, `npm install -g typescript@<v> tsx@<v> eslint@<v> prettier@<v> pyright@<v> playwright@<v>`, `uv tool install ruff@<v>`, and resolve yq/lazygit to a pinned tag in install-tools.sh (which also enables the checksum check from the related finding). Add a brief CLAUDE.md note that these are intentionally pinned and how to bump them, so the choice isn't "simplified" back to `@latest`. A dependency bot can automate the cadence.

## Pinned-by-tag base images, not by digest — no content integrity across rebuilds

- **Severity / kind:** low / security
- **Location:** [`.devcontainer/Dockerfile:15`](.devcontainer/Dockerfile#L15)
- **Evidence:**

  ```
  FROM node:24-bookworm  (Dockerfile:15)
  image: pgvector/pgvector:pg18 (compose.yaml:52)
  ```

  A grep for `@sha256:` across the repo returns "NONE — no image digests pinned".
- **Why it matters:** `node:24-bookworm` and `pgvector/pgvector:pg18` are mutable tags: the bytes they resolve to change whenever upstream re-pushes. A `make rebuild` weeks apart can silently pull a different base layer (including a compromised or regressed one) with no signal in git. For a project whose explicit value proposition is a security sandbox, the foundation layer should be reproducible and tamper-evident. This is defense-in-depth, not a live bug — the comment at Dockerfile:7-11 even reasons about the multi-arch manifest, which digest-pinning interacts with.
- **Recommendation:** Pin both images by digest in addition to the human tag: `FROM node:24-bookworm@sha256:<digest>` in `.devcontainer/Dockerfile` and `image: pgvector/pgvector:pg18@sha256:<digest>` in `.devcontainer/compose.yaml`. For multi-arch, pin the manifest-list digest (Docker resolves the per-arch image under it, preserving the no-emulation property). Record a short note in CLAUDE.md on how to bump the digest (e.g. `docker buildx imagetools inspect node:24-bookworm`). Optionally add Dependabot/renovate for Docker digests to keep the bump cadence sane.

## Release binaries fetched with no checksum or signature verification (yq, lazygit, AWS CLI, cargo-binstall, uv, Claude)

- **Severity / kind:** low / security
- **Location:** [`.devcontainer/install-tools.sh:41`](.devcontainer/install-tools.sh#L41)
- **Evidence:**

  ```
  yq:            curl .../releases/latest/download/yq_linux_${GO_ARCH} -o /usr/local/bin/yq (install-tools.sh:41-43)
  lazygit:       tarball from releases/download piped to tar with no hash (install-tools.sh:46-51)
  AWS CLI:       curl awscli-exe-linux-*.zip then unzip+install, no GPG (install-tools.sh:62-65)
  cargo-binstall: bootstrap piped from the `main` branch to bash (install-tools.sh:21-22)
  uv:            astral.sh/uv/install.sh | sh (Dockerfile:202)
  Claude:        claude.ai/install.sh | bash (Dockerfile:207)
  ```

  A grep for `sha256|checksum|gpg --verify|cosign` across the repo: "NO checksum/signature verification found anywhere".
- **Why it matters:** Every third-party binary baked into the image is trusted purely on TLS-to-the-right-host. There is no second factor (published SHA256SUMS, GPG signature, cosign) confirming the artifact wasn't swapped by a registry/CDN compromise or a release-pipeline takeover. AWS specifically publishes a detached GPG signature (`awscli-exe-linux-<arch>.zip.sig`) and a public key precisely so installers can verify — the script skips it. cargo-binstall is bootstrapped from the floating `main` branch (install-tools.sh:22), so even the bootstrapper itself is unpinned. These run at build time as root with unrestricted network, so a poisoned artifact compromises the image before the firewall ever exists. This is the classic supply-chain gap for a "security" image.
- **Recommendation:** In `.devcontainer/install-tools.sh`, add verification per tool: for the AWS CLI, also fetch `...zip.sig`, import the AWS CLI public key, and `gpg --verify` before running the installer; for yq and lazygit, pin an explicit version and check the published SHA256 (both ship `checksums.txt` on their releases) — e.g. download, `sha256sum -c`, then install. Pin cargo-binstall's bootstrap to a tagged release script (a `vX.Y.Z` ref) instead of `main`, or install it via a checksummed release asset. For the `| sh`/`| bash` installers (uv at Dockerfile:202, Claude at :207, cargo-binstall at :22), where upstream offers no easy checksum, at minimum pin the installer to a versioned URL where available and add a comment documenting the residual trust. Even adding checksums to just yq/lazygit/AWS closes the most tractable gaps.
