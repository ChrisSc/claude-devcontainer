# supply-chain — audit findings

The supply chain of this image is, by deliberate design, fetch-latest from end
to end: the audit found no pinning layer of any kind — no base-image digest, no
lockfiles, no apt version pins, no checksum or signature gates on the raw binary
downloads, and no SBOM or provenance attestation. Every external artifact in the
build graph (base image, ~50 apt packages across two third-party repos, 11 cargo
binaries, 6 npm globals plus pnpm and their transitive trees, Playwright
Chromium, CPython, ruff, uv, cargo-binstall, yq, lazygit, AWS CLI, 3 zsh plugins,
and the Claude installer) independently resolves to "newest at build time." The
result is an image that is neither reproducible nor tamper-evident, with no
detection mechanism across the entire build surface. Because all of this work
happens at build time, the runtime firewall provides zero mitigation. Findings
cluster into five high-severity unverified-download issues (AWS CLI, base image,
lazygit, the three curl|bash installers, yq) and five medium-severity
reproducibility/trust gaps (cargo-binstall trust policy, npm/pnpm floating
latest, the systemic no-pinning finding, third-party apt key trust, and
branch-HEAD zsh plugins).

## AWS CLI v2 bundle fetched latest and installed with no GPG signature verification

- **Severity / kind:** high / security
- **Location:** [.devcontainer/install-tools.sh:62](.devcontainer/install-tools.sh#L62)
- **Evidence:**

  > install-tools.sh:62-65 — curl awscli-exe-linux-${AWS_ARCH}.zip -o awscliv2.zip; unzip; "${AWS_TMP}/aws/install". No download of the matching .zip.sig and no `gpg --verify`.

- **Why it matters:** `awscli.amazonaws.com/awscli-exe-linux-<arch>.zip` is the
  rolling latest AWS CLI v2 (version drifts every build → non-reproducible) and
  is installed by running `./aws/install` from inside the unzipped archive with
  no integrity gate. AWS explicitly publishes a detached PGP signature
  (`.zip.sig`) and a public key precisely so this installer can be verified
  before execution — the documented secure install procedure is skipped. A
  substituted archive (CDN compromise, cache poisoning, or rogue-CA MITM in the
  build network) executes its bundled `./aws/install` as root. This is the
  largest single binary blob in the build and runs an arbitrary installer script
  from it unverified.
- **Recommendation:** Follow AWS's documented verified install: import the AWS
  CLI public PGP key, download `awscliv2.zip` AND `awscliv2.sig`, `gpg --verify`
  before unzip, and pin a specific CLI version via the versioned download path if
  reproducibility is required. Do not run `./aws/install` on an unverified
  archive.

## Base image FROM node:24-bookworm is a floating tag, never digest-pinned

- **Severity / kind:** high / bug
- **Location:** [.devcontainer/Dockerfile:15](.devcontainer/Dockerfile#L15)
- **Evidence:**

  > FROM node:24-bookworm  (no @sha256: digest; comment at Dockerfile:7 even notes "node:24-bookworm is a multi-arch manifest")

- **Why it matters:** The entire image is built on top of whatever
  `node:24-bookworm` resolves to at build time. The tag is mutable — Docker Hub
  re-publishes it on every Node 24.x patch and every Debian bookworm security
  roll. Two builds of this exact Dockerfile days apart produce different base
  layers (different glibc, openssl, system libs), so the build is not
  reproducible, and a compromised or maliciously re-pushed upstream tag is
  silently inherited with no detection. This is the root of the supply chain:
  everything else (npm globals, Playwright/Chromium, uv, Claude) is layered on an
  unpinned foundation. There is no digest pin anywhere in the repo (grep for
  `sha256:` across yaml/json/Dockerfile returns nothing).
- **Recommendation:** Pin by digest: `FROM node:24-bookworm@sha256:<digest>`.
  Record the digest in-repo and bump it deliberately (Dependabot/renovate can PR
  digest updates). This keeps multi-arch (the digest of a manifest list still
  resolves per-arch) while making the base layer reproducible and tamper-evident.

## lazygit version resolved live from GitHub API (fetch-latest) and tarball extracted without checksum

- **Severity / kind:** high / security
- **Location:** [.devcontainer/install-tools.sh:46](.devcontainer/install-tools.sh#L46)
- **Evidence:**

  > install-tools.sh:46-51 — LG_VER=$(curl ... api.github.com/repos/jesseduffield/lazygit/releases/latest | grep -Po '"tag_name":...'); then curl the v${LG_VER} tarball | tar -xz -C /usr/local/bin lazygit; chmod +x. No checksums_*.txt verification.

- **Why it matters:** Version is whatever the GitHub API reports as 'latest' at
  build time, so lazygit drifts every build (non-reproducible) AND the build
  depends on the unauthenticated `api.github.com` response being well-formed (a
  transient API outage/rate-limit returns JSON without `tag_name` → `LG_VER`
  empty → it fetches `.../download/v/lazygit__Linux_....tar.gz`, a
  guaranteed-wrong URL; with the pipe to tar the curl failure may not abort
  cleanly). The downloaded tarball is piped straight into tar and the extracted
  binary made executable with no checksum, despite jesseduffield/lazygit
  publishing `checksums.txt` per release. Same tamper exposure as yq.
- **Recommendation:** Pin `LG_VER` to an explicit version instead of querying
  `releases/latest`. Download the tarball to a temp file, fetch the release
  `checksums.txt`, verify with `sha256sum -c`, then extract. Drop the API call
  entirely (it adds an unauthenticated rate-limited dependency to the build).

## Three curl|bash pipe-to-shell installers run unpinned and unverified at build (cargo-binstall, uv, Claude)

- **Severity / kind:** high / security
- **Location:** [.devcontainer/install-tools.sh:21](.devcontainer/install-tools.sh#L21)
- **Evidence:**

  > install-tools.sh:21-22 `curl ... https://raw.githubusercontent.com/cargo-bins/cargo-binstall/main/install-from-binstall-release.sh | bash`; Dockerfile:202 `curl -LsSf https://astral.sh/uv/install.sh | sh`; Dockerfile:207 `curl -fsSL https://claude.ai/install.sh | bash`

- **Why it matters:** All three fetch a remote shell script and execute it
  immediately with no checksum or signature gate, and all three reference moving
  targets: cargo-binstall pulls `install-from-binstall-release.sh` from the
  `main` branch (HEAD of the repo at build time — any commit to that branch
  changes what runs as root), uv's installer is the unversioned latest, and
  Claude's installer is latest. A compromise of `raw.githubusercontent.com`
  content, the `astral.sh` CDN, the `claude.ai` install endpoint, or a forced
  redirect yields arbitrary root-level (cargo-binstall/uv run as root in section
  2/early; claude runs as the claude user) code execution baked permanently into
  the image. Pipe-to-shell also means a truncated/partial download can execute a
  half-script. Note this is the documented design ('build-time downloads are
  unrestricted', Dockerfile:14) — the firewall does not cover any of it.
- **Recommendation:** Pin each installer to a released, versioned URL (e.g.
  cargo-binstall's `install-from-binstall-release.sh` at a tagged release, uv's
  versioned installer URL, a pinned Claude installer version), download to a temp
  file, verify a known SHA256 (or GPG signature where published — uv publishes
  checksums), then execute. At minimum replace the cargo-binstall `main` branch
  ref with a release tag so HEAD-of-branch can't change what executes.

## yq downloaded from releases/latest with no version pin and no checksum

- **Severity / kind:** high / security
- **Location:** [.devcontainer/install-tools.sh:41](.devcontainer/install-tools.sh#L41)
- **Evidence:**

  > curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${GO_ARCH}" -o /usr/local/bin/yq  (then chmod +x; no sha256sum -c)

- **Why it matters:** The `/releases/latest/` redirect resolves to whatever the
  newest tag is at build time, so the yq version drifts build-to-build
  (non-reproducible) and the raw binary is written straight to `/usr/local/bin`
  and made executable with zero integrity check. mikefarah/yq publishes a
  `checksums.txt` and per-asset `.sig` with every release, none of which is
  consulted. A tampered or substituted asset (compromised GitHub release, MITM
  despite TLS via a rogue CA in the build env, or a malicious new release) lands
  as an executable on PATH for every user with no detection.
- **Recommendation:** Pin a specific yq version (`YQ_VER`), fetch
  `yq_linux_${GO_ARCH}` AND the release's `checksums.txt`, and `sha256sum -c` (or
  verify the GPG `.sig` against mikefarah's published key) before `chmod +x`.
  Apply the same pattern uniformly to all three direct downloads.

## cargo-binstall pulls 11 prebuilt binaries with no --locked / signature policy; default trust is permissive

- **Severity / kind:** medium / security
- **Location:** [.devcontainer/install-tools.sh:27](.devcontainer/install-tools.sh#L27)
- **Evidence:**

  > install-tools.sh:27-38 — `cargo-binstall --no-confirm --install-path /usr/local/bin eza zoxide starship git-delta bottom du-dust procs sd hyperfine tokei tealdeer` (no version constraints, no --strategy, no signing policy)

- **Why it matters:** Every crate is unversioned, so cargo-binstall resolves each
  to the newest version on crates.io at build time (11 tools drifting
  independently → non-reproducible) and downloads a prebuilt release artifact
  from each project's GitHub releases. cargo-binstall fetches *prebuilt binaries*
  (not source compiled from a Cargo.lock), and absent an explicit signing policy
  it does not require the artifacts to be signed — it trusts whatever the
  upstream release hosts serve. A compromise of any one of these 11 upstream
  release pipelines (a well-known supply-chain vector for popular CLI tools)
  silently lands an executable on PATH. There is no Cargo.lock in the repo (find
  for `*.lock` returns nothing) to constrain versions.
- **Recommendation:** Pin each crate to an explicit version (`eza@x.y.z` ...) so
  the binary set is reproducible, and where a tool ships signed artifacts use
  cargo-binstall's signing-policy/`--strategy` controls (or fall back to
  `cargo install --locked` from source for the security-sensitive ones). At
  minimum pin versions to make the install reproducible and auditable.

## Global npm tooling and pnpm installed at floating latest with no lockfile (pnpm@latest, unpinned npm -g)

- **Severity / kind:** medium / security
- **Location:** [.devcontainer/Dockerfile:100](.devcontainer/Dockerfile#L100)
- **Evidence:**

  > Dockerfile:100 `corepack prepare pnpm@latest --activate`; Dockerfile:101 `npm install -g typescript tsx eslint prettier pyright playwright` (no @version on any package, no --no-fund/--ignore-scripts, no lockfile)

- **Why it matters:** pnpm@latest and six globally-installed npm packages
  (typescript, tsx, eslint, prettier, pyright, playwright) are all resolved to
  newest at build time, so the toolchain drifts every build (non-reproducible)
  and the build trusts whatever the npm registry serves for each name + its full
  transitive dependency tree. npm runs package install scripts by default, so any
  one of those packages or any transitive dependency can execute arbitrary code
  as root during `npm install -g` (classic npm supply-chain RCE surface). There
  is no package-lock.json / pnpm-lock.yaml in the repo to pin the tree.
  playwright's version here also floats independently of the Chromium pinned by
  `playwright install chromium` at Dockerfile:104, risking a browser/driver
  version skew.
- **Recommendation:** Pin pnpm to an explicit version (`pnpm@x.y.z`) and pin each
  global npm package to an exact version. Commit a lockfile and install from it,
  or use `npm ci`-style pinning. Consider `npm install -g --ignore-scripts` for
  the global tools that don't need install scripts to reduce arbitrary-code
  exposure.

## No lockfiles, image digest, or provenance anywhere — the whole build is fetch-latest by construction

- **Severity / kind:** medium / maintainability
- **Location:** [.devcontainer/Dockerfile:13](.devcontainer/Dockerfile#L13)
- **Evidence:**

  > Repo-wide: `find` for *.lock/package-lock.json/pnpm-lock.yaml/Cargo.lock returns nothing; grep for sha256:/content_trust/cosign/provenance/sbom across Dockerfile/Makefile/yaml/sh returns nothing; comment at Dockerfile:13-14 'Everything in this image is installed at BUILD time ... build-time downloads are unrestricted.'

- **Why it matters:** This is the cross-cutting, systemic finding a per-file
  review misses: there is no pinning layer of any kind in the project. No
  base-image digest, no apt version pins, no Cargo.lock, no npm lockfile, no
  checksum manifest, no SBOM, no Docker content-trust / provenance attestation.
  Every external artifact in the build graph (base image, ~50 apt packages across
  two third-party repos, 11 cargo binaries, 6 npm globals + pnpm + their
  transitive trees, Playwright Chromium, CPython, ruff, uv, cargo-binstall, yq,
  lazygit, AWS CLI, 3 zsh plugins, the Claude installer) independently resolves
  to 'newest at build time'. Consequence: the image is not reproducible (you
  cannot rebuild byte-identical, cannot bisect a regression to a dependency,
  cannot attest what shipped) and has no detection mechanism for any upstream
  tamper across that entire surface. Because all of this is deliberately outside
  the runtime firewall, the firewall provides zero mitigation for build-time
  supply-chain risk.
- **Recommendation:** Establish a pinning discipline as a first-class artifact:
  digest-pin the base image; pin apt, cargo, npm/pnpm, uv/python/ruff, yq,
  lazygit, AWS CLI, and zsh-plugin versions; commit lockfiles where the ecosystem
  supports them; add a checksum-verify step for every raw binary download; and
  generate an SBOM at build (e.g. syft) so the shipped dependency set is recorded
  and auditable. Adopt renovate/Dependabot to bump the pins deliberately rather
  than implicitly on every build.

## Two third-party apt repos added by fetching keys over HTTPS with no key-fingerprint verification (GitHub CLI, PGDG)

- **Severity / kind:** medium / security
- **Location:** [.devcontainer/Dockerfile:32](.devcontainer/Dockerfile#L32)
- **Evidence:**

  > Dockerfile:32-36 fetches githubcli-archive-keyring.gpg from cli.github.com and trusts it directly for the gh apt repo; Dockerfile:64-67 fetches ACCC4CF8.asc from postgresql.org and trusts it for the PGDG repo. No expected-fingerprint check on either key.

- **Why it matters:** Both repos are bootstrapped by curl-ing a signing key over
  TLS and immediately wiring it into apt's `signed-by` trust with no out-of-band
  fingerprint verification. TLS authenticates the host but not the key contents;
  if either key-hosting endpoint is compromised or MITM'd via a rogue CA present
  in the build environment, an attacker-supplied key is trusted and apt then
  installs attacker-signed gh / postgresql-client-18 packages that pass signature
  checks. Pinning the apt package versions is also absent, so gh and the pg18
  client float to newest at build (reproducibility), but the key-trust gap is the
  security-relevant issue.
- **Recommendation:** Verify each downloaded key's fingerprint against a
  hardcoded expected value before installing it (e.g. `gpg --show-keys` and
  compare to GitHub's / PostgreSQL's published fingerprint), failing the build on
  mismatch. Optionally pin gh and postgresql-client-18 to explicit versions for
  reproducibility.

## zsh plugins cloned from branch HEAD (--depth 1, no commit pin) and sourced into every shell

- **Severity / kind:** medium / security
- **Location:** [.devcontainer/Dockerfile:83](.devcontainer/Dockerfile#L83)
- **Evidence:**

  > Dockerfile:82-89 — `git clone --depth 1 https://github.com/zsh-users/zsh-autosuggestions ...`, same for zdharma-continuum/fast-syntax-highlighting and zsh-users/zsh-completions; then `rm -rf /usr/share/zsh-plugins/*/.git`

- **Why it matters:** Each `git clone --depth 1` with no `--branch <tag>`/checkout
  pins to the default branch's HEAD at build time, so the exact plugin code is
  non-reproducible and is whatever the maintainer last pushed. These plugins are
  sourced into every interactive zsh as the claude user (.zshrc), so a
  compromised upstream push (the zdharma org has prior supply-chain history — the
  original zdharma was abandoned/hijacked, which is why the fork
  zdharma-continuum exists) executes in the user's shell on every login.
  Stripping `.git` afterward also destroys the only record of which commit was
  installed, making post-hoc auditing impossible.
- **Recommendation:** Clone a pinned tag or commit: `git clone --depth 1 --branch
  <tag>` then optionally `git checkout <sha>` before removing `.git`, and record
  the commit SHAs in-repo. This makes the plugin set reproducible and
  tamper-evident while keeping the shallow clone.
