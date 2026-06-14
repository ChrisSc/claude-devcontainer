# build — audit findings

The build area is functional but carries a recurring theme of **fail-open
supply-chain risk and non-reproducibility**. The highest-severity issue is that
the Dockerfile never sets a `pipefail`-enabled `SHELL`, so every `curl | bash`
install layer (most critically the final Claude Code install) can silently
succeed while installing nothing. Compounding that, nearly all build-time
binaries (yq, lazygit, AWS CLI, pnpm, npm globals, uv, cargo-binstall) are
fetched from floating `latest`/`main` refs with no checksum or signature
verification while running as root on an unrestricted pre-firewall network —
both a supply-chain attack surface and a barrier to reproducible builds. A
missing `.dockerignore` needlessly ships the plaintext Postgres secret into the
build context, and a root-run CRLF-strip silently reverts `--chown=claude:claude`
ownership on baked dotfiles. None of these brick the container today, but
several are one small change away from a real failure or leak. Findings below
are ordered by severity.

## Dockerfile sets no SHELL, so `curl ... | bash` install layers mask curl failures (no pipefail)

- **Severity / kind:** high / bug
- **Location:** [.devcontainer/Dockerfile:207](.devcontainer/Dockerfile#L207)
- **Evidence:**

  > Line 207: `RUN curl -fsSL https://claude.ai/install.sh | bash` — and there is no `SHELL ["/bin/bash", "-o", "pipefail", "-c"]` directive anywhere in the Dockerfile (grep for `^SHELL` returns nothing), so every RUN executes under the default `/bin/sh -c` (dash on Debian), which has no `pipefail`.

- **Why it matters:** In a `cmd1 | cmd2` pipeline without `pipefail`, the exit
  status is that of the LAST command (`bash`), not `curl`. If `curl -fsSL` fails
  on a transient error (DNS hiccup, 5xx, captive-portal/redirect to an HTML
  error page), `-f` makes curl exit non-zero but that code is discarded; `bash`
  reads empty or partial input, exits 0, and Docker caches the layer as a
  SUCCESS. The result is an image that is silently missing or has a
  half-installed Claude Code binary. Line 207 is the worst case because it is a
  standalone RUN with neither `set -e` nor `pipefail`. (The CLAUDE.md file map
  and entrypoint treat `claude` as guaranteed-present; a masked failure here
  breaks `claude update` and the whole point of the image.)
- **Recommendation:** Add `SHELL ["/bin/bash", "-o", "pipefail", "-c"]` near the
  top of the Dockerfile so all pipelines fail closed. Additionally, prefer
  fetch-then-verify-then-execute: `curl -fsSL https://claude.ai/install.sh -o
  /tmp/claude.sh && bash /tmp/claude.sh` so a failed download aborts the build.

## Build-time binaries fetched with no checksum/signature verification and floating `latest`/`main` refs

- **Severity / kind:** medium / security
- **Location:** [.devcontainer/install-tools.sh:21](.devcontainer/install-tools.sh#L21)
- **Evidence:**

  > install-tools.sh:22 pipes `https://raw.githubusercontent.com/cargo-bins/cargo-binstall/main/install-from-binstall-release.sh | bash` (branch `main`, no pin/verify); :41 `curl ... yq/releases/latest/download/yq_linux_${GO_ARCH}` straight to `/usr/local/bin/yq` (no sha256); :46-50 lazygit `releases/latest` then download+`tar -xz` (no checksum); :62-65 AWS CLI zip with no signature check. Dockerfile:100 `corepack prepare pnpm@latest`; :101 `npm install -g typescript tsx eslint prettier pyright playwright` (all unpinned); :202/:207 uv + Claude installers piped to a shell. The only verified fetches are the apt repo keys (gh, PGDG).

- **Why it matters:** Every one of these runs as root at build time with
  unrestricted network (the firewall is runtime-only, per CLAUDE.md). HTTPS
  authenticates the host but not the artifact: a compromised upstream release, a
  hijacked `latest`/`main` tag, or a MITM at any CDN edge bakes
  attacker-controlled code into the image with no detection. The floating refs
  (`latest`, `main`, `@latest`) also make builds non-reproducible — two builds
  days apart yield different toolchains, so a regression or a poisoned release
  can't be bisected or attributed.
- **Recommendation:** Pin explicit versions for yq, lazygit, AWS CLI, pnpm, and
  the npm globals, and verify a published SHA-256 (or GPG signature where
  available, e.g. AWS CLI provides a `.sig`) before placing the binary on PATH.
  At minimum pin cargo-binstall to a tagged release instead of `main`. Where
  pinning is impractical, document the trade-off in a comment as the org
  standard requires for deliberate deviations.

## install-tools.sh AWS CLI install runs the downloaded `aws/install` as root with no integrity check — full RCE surface at build, but also no verification the bundle is the official one

- **Severity / kind:** medium / security
- **Location:** [.devcontainer/install-tools.sh:65](.devcontainer/install-tools.sh#L65)
- **Evidence:**

  > curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip -o ...zip; unzip ...; "${AWS_TMP}/aws/install"  (executed as the root build user, no GPG)

- **Why it matters:** Prior findings noted 'no GPG signature' generically, but
  the specific severity here is that AWS publishes a detached PGP signature for
  exactly this bundle and the official docs' install procedure verifies it; this
  script skips that and then *executes the unpacked installer script as root*. A
  compromised mirror/MITM (the build network is unrestricted and pre-firewall)
  yields arbitrary root code execution baked into the image, not merely a bad
  binary. This is a strictly higher-impact instance than the yq/lazygit
  'download-only' cases because the payload is run, not just placed on PATH.
- **Recommendation:** Fetch the matching `.sig`, import AWS's public key, and
  `gpg --verify awscliv2.sig awscliv2.zip` before unzip/install (the
  AWS-documented procedure); fail the build on mismatch. Same pattern applies to
  the cargo-binstall and uv install.sh pipes.

## No .dockerignore: generated .env (Postgres password) is sent into the build context

- **Severity / kind:** medium / security
- **Location:** [.devcontainer/Dockerfile](.devcontainer/Dockerfile)
- **Evidence:**

  > Build context is `.devcontainer` (compose.yaml:14 `context: .`). `.devcontainer/.env` exists (702 bytes, contains POSTGRES_PASSWORD/PGPASSWORD/DATABASE_URL via gen-env.sh:32-42) and there is no `.devcontainer/.dockerignore` (find returned none). `.env` is gitignored but NOT docker-ignored.

- **Why it matters:** Without a .dockerignore, the entire context — including the
  plaintext DB secret `.env`, `.env.example`, `db-backups/` if present, and
  `config/extra-allowlist.txt` (may hold private LAN IPs) — is transferred to the
  Docker daemon on every build. The current Dockerfile happens not to `COPY .env`,
  so the secret does not land in an image layer, but the build is one stray
  `COPY . .`/`COPY .env*` away from baking the password into a shared layer, and
  the secret is needlessly exposed to the daemon/build cache. This is a latent
  leak with no upside.
- **Recommendation:** Add `.devcontainer/.dockerignore` listing at minimum
  `.env`, `.env.example` (templates aren't needed in-image), `db-backups/`,
  `config/extra-allowlist.txt` is COPY'd so keep it, plus `*.md`/`Makefile` if
  not needed. This also speeds builds by shrinking the context.

## lazygit/yq pinned to :latest at build time — non-reproducible builds

- **Severity / kind:** low / maintainability
- **Location:** [.devcontainer/install-tools.sh:41](.devcontainer/install-tools.sh#L41)
- **Evidence:**

  > yq: `.../releases/latest/download/yq_linux_${GO_ARCH}` (line 41). lazygit: `curl .../releases/latest | grep -Po '"tag_name"...'` then downloads that tag (lines 46-50). AWS CLI: `awscli-exe-linux-${AWS_ARCH}.zip` (always-latest, line 62). cargo-binstall installer fetched from `main` branch (line 22).

- **Why it matters:** Every rebuild can pull a different upstream version of yq,
  lazygit, AWS CLI, and the cargo-binstall bootstrap. This is fine for a personal
  sandbox but means two `make rebuild`s days apart are not byte-identical, and a
  breaking upstream release (e.g. an AWS CLI that changes `aws sso login`
  behavior, or a yq v5 syntax break) lands silently with no changelog gate. The
  lazygit path is also fragile: if the GitHub API rate-limits the unauthenticated
  `releases/latest` call during build, `LG_VER` is empty and the download URL
  becomes `.../v/lazygit__Linux_...tar.gz` (404) — though `set -euo pipefail`
  (line 11) correctly aborts the build in that case.
- **Recommendation:** Pin explicit versions for at least yq, lazygit, and AWS CLI
  (e.g. `LG_VER=0.44.1` as an ARG), or accept the drift and document it. Pinning
  the cargo-binstall installer to a tag instead of `main` removes a supply-chain
  wildcard.

## Pipe-to-shell installers (uv, claude) can silently no-op: RUN uses /bin/sh without pipefail

- **Severity / kind:** low / bug
- **Location:** [.devcontainer/Dockerfile:207](.devcontainer/Dockerfile#L207)
- **Evidence:**

  > Line 207 `RUN curl -fsSL https://claude.ai/install.sh | bash` and line 202 `curl -LsSf https://astral.sh/uv/install.sh | sh`. No `SHELL ["/bin/bash","-o","pipefail","-c"]` directive and no `set -o pipefail` in any RUN (grep confirmed). hadolint flags both as DL4006.

- **Why it matters:** Docker's default RUN shell is `/bin/sh -c`, which does not
  set pipefail. If the `curl` fails mid-build (transient network, CDN blip, or a
  future firewall ordering change), the downstream `bash`/`sh` receives
  empty/partial stdin, runs nothing, and exits 0 — so the build succeeds with
  Claude Code (line 207) or uv missing. Line 202 is partly protected because line
  203 `uv python install` would then fail, but line 207 is the final build step
  with no in-build verification, so a broken/absent `claude` only surfaces at
  container runtime via the entrypoint.
- **Recommendation:** Add `SHELL ["/bin/bash", "-o", "pipefail", "-c"]` before
  these RUNs (note: changes apply to subsequent RUNs), or inline-guard, e.g.
  `RUN set -o pipefail; curl ... | bash` won't work under sh — instead `curl
  -fsSL ... -o /tmp/i.sh && bash /tmp/i.sh`. At minimum add a post-install
  assertion: `command -v claude` after line 207.

## `sed -i` CRLF-strip runs as root and discards `COPY --chown=claude:claude` on baked dotfiles

- **Severity / kind:** low / bug
- **Location:** [.devcontainer/Dockerfile:152](.devcontainer/Dockerfile#L152)
- **Evidence:**

  > Lines 140-141 copy `home/.zshrc` and `home/.config/` with `COPY --chown=claude:claude`. The first `USER` directive is at line 174. The CRLF normalization at lines 152 (`sed -i 's/\r$//' ... /home/claude/.zshrc`) and 163 (`find /home/claude/.config -type f -exec sed -i 's/\r$//' {} +`) therefore execute as root, and `sed -i` rewrites via temp-file + atomic rename, which yields a file owned by the running user (root).

- **Why it matters:** After this step `/home/claude/.zshrc`,
  `/home/claude/.config/starship.toml`, and
  `/home/claude/.config/zsh/aliases.zsh` are owned `root:root`, silently undoing
  the explicit `--chown=claude:claude`. Practical breakage is limited because the
  files keep their read mode and the `claude` user only reads them (compinit
  writes `~/.zcompdump` into `$HOME`, which stays claude-owned), but it is an
  ownership drift that contradicts the stated intent and would bite any tool that
  later tries to rewrite one of these dotfiles in place as the `claude` user
  (permission denied). It also means the only thing keeping this working is that
  nothing writes back to those paths.
- **Recommendation:** Either run the CRLF strip before the `COPY --chown` (e.g.
  normalize the sources) or re-assert ownership after the sed block: add `chown
  claude:claude /home/claude/.zshrc` and `find /home/claude/.config -exec chown
  claude:claude {} +` at the end of the RUN at lines 151-169 (still as root,
  before `USER claude`).

## apt/npm packages unpinned (hadolint DL3008/DL3016) — advisory

- **Severity / kind:** nit / maintainability
- **Location:** [.devcontainer/Dockerfile:38](.devcontainer/Dockerfile#L38)
- **Evidence:**

  > hadolint (via Docker image) reports: `-:27 DL3008` and `-:62 DL3008` (apt-get install without `=version`) and `-:97 DL3016` (`npm install -g typescript tsx ... ` without `@version`). Lines 38-46 (apt core+firewall+CLI), 62-69 (pg client), 97-101 (npm globals).

- **Why it matters:** Unpinned apt and npm versions mean rebuilds float to
  whatever the repos currently serve. For a moving dev sandbox this is the
  intended trade-off (you want fresh tools), so it's not a defect — but it is the
  documented hadolint signal and worth an explicit decision. Note
  `postgresql-client-18` (line 69) IS major-pinned, which is the load-bearing
  constraint (must match pgvector/pgvector:pg18 server, compose.yaml:52) — that
  part is correct.
- **Recommendation:** No action required for a personal sandbox; if
  reproducibility matters, pin majors. Optionally silence with a top-of-file `#
  hadolint ignore=DL3008,DL3016` and a comment that floating versions are
  intentional for a dev image.
