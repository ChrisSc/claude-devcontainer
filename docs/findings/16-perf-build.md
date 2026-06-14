# perf-build — audit findings

The build pipeline is functional and the repo invests in cross-platform reproducibility (multi-arch, LF enforcement, baked timezone), but the Docker build layer leaves real value on the table. The most serious issue is a security gap rather than a pure performance one: the absence of a `.dockerignore` ships the gitignored `.env` Postgres-password secret into the build context on every build. Beyond that, BuildKit is enabled but unused for caching, so every rebuild re-downloads hundreds of MB of apt/npm/cargo/Chromium artifacts; floating versions make builds non-reproducible; an implicit apt invocation bloats the image; and a handful of redundant `chmod` calls add noise. None of these break the container, but together they slow rebuilds, undermine reproducibility, and weaken secret handling.

## No .dockerignore: secret .env and unused config files are shipped into the build context

- **Severity / kind:** high / security
- **Location:** [.devcontainer/Dockerfile](.devcontainer/Dockerfile) (build context, no line)
- **Evidence:**
  > No .dockerignore exists at repo root or in .devcontainer/ (verified absent). compose.yaml:14 sets `context: .` (resolved from .devcontainer/), so the entire .devcontainer/ tree is sent to the Docker daemon as build context. `du` of the context shows ./.env (the gitignored DB-password secret), .env.example, compose.yaml, devcontainer.json, gen-env.sh, gen-allowlist.sh, and db-init/ — none of which are consumed by any Dockerfile COPY (the only COPY sources are install-tools.sh, home/, seed/, the *.sh scripts, crontab-*, and config/extra-allowlist.txt).
- **Why it matters:** The generated `.devcontainer/.env` holds the strong Postgres password (`gen-env.sh`) and is gitignored precisely so it never leaves the host — but with no `.dockerignore` it is transferred to the Docker daemon on every build and is retrievable from the daemon's context/cache, defeating the gitignore. Separately, mutating any non-build file in the context (e.g. editing `compose.yaml` or `devcontainer.json`) needlessly re-transfers context and can perturb cache behavior. This is a real secret-handling gap, not just a perf nit.
- **Recommendation:** Add `.devcontainer/.dockerignore` listing everything the build does NOT consume: `.env`, `.env.example`, `compose.yaml`, `devcontainer.json`, `gen-env.sh`, `gen-allowlist.sh`, `db-init/`, plus `config/extra-allowlist.txt.example`. Keep only the actual COPY sources. Document it in CLAUDE.md's File map alongside the existing build-context invariants.

## BuildKit is enabled but no --mount=type=cache is used; every rebuild re-downloads apt, npm, cargo, and Chromium

- **Severity / kind:** medium / perf
- **Location:** [.devcontainer/Dockerfile:27](.devcontainer/Dockerfile#L27)
- **Evidence:**
  > Line 1 is `# syntax=docker/dockerfile:1` (BuildKit on), but `grep -c 'mount=type=cache'` returns 0. The heavy network RUN layers — apt installs (Dockerfile:27-56, 62-70), `npm install -g typescript tsx eslint prettier pyright playwright` + `playwright install chromium` (Dockerfile:97-106), and install-tools.sh's `cargo-binstall ... eza zoxide starship git-delta bottom du-dust procs sd hyperfine tokei tealdeer` + AWS CLI + lazygit/yq (install-tools.sh:27-66) — all fetch from the network with zero persistent cache.
- **Why it matters:** `make rebuild` does `--no-cache`, and any edit early in the Dockerfile invalidates all downstream layers, forcing full re-downloads of hundreds of MB (Chromium alone, the apt package set, ~11 prebuilt Rust binaries, the AWS CLI zip). BuildKit cache mounts persist these across builds even on cache-busting rebuilds, cutting rebuild time substantially without changing image contents (cache mounts are not part of the final image).
- **Recommendation:** Add cache mounts to the network-bound RUN layers: `--mount=type=cache,target=/var/cache/apt,sharing=locked --mount=type=cache,target=/var/lib/apt/lists,sharing=locked` on the apt RUN blocks (and drop the in-layer `apt-get clean`/`rm -rf` so the cache survives), `--mount=type=cache,target=/root/.npm` on the npm/playwright layer, and `--mount=type=cache,target=/root/.cargo` on the install-tools.sh layer (Dockerfile:77). Consider `--mount=type=cache,target=/usr/local/share/ms-playwright-cache` keyed to a pinned Playwright version for the browser download.

## Floating versions (pnpm@latest, GitHub 'latest' release URLs) defeat layer caching and make builds non-reproducible

- **Severity / kind:** low / maintainability
- **Location:** [.devcontainer/install-tools.sh:41](.devcontainer/install-tools.sh#L41)
- **Evidence:**
  > Dockerfile:100 `corepack prepare pnpm@latest --activate`; install-tools.sh:41 fetches `.../yq/releases/latest/download/...`; install-tools.sh:46 resolves lazygit via `.../releases/latest`. cargo-binstall crates (install-tools.sh:27-38) and the npm globals (Dockerfile:101) are likewise unpinned. None of these change the layer's instruction text, so Docker reuses a stale cached layer even when upstream ships a new release — yet a cache-busting rebuild silently pulls a different toolchain.
- **Why it matters:** This is the worst-of-both-worlds for caching: with the cache warm you get whatever version was first built (no upgrades), and on `--no-cache` you get an unpredictable newer version with no record of what shipped. It also undermines the cross-platform reproducibility the repo otherwise invests in (multi-arch, LF enforcement). A breaking pnpm/lazygit/yq release can change container behavior with no Dockerfile diff.
- **Recommendation:** Pin versions: `corepack prepare pnpm@<X.Y.Z>` in Dockerfile:100, a fixed `yq` tag and `LG_VER` in install-tools.sh (replace the `/latest` lookups with explicit versions), and explicit npm-global versions in Dockerfile:101. Keep them in a single ARG/var block so a Dependabot-style bump is one diff and the cache invalidates intentionally.

## playwright install-deps runs apt internally but its apt lists are never cleaned, bloating the image layer

- **Severity / kind:** low / perf
- **Location:** [.devcontainer/Dockerfile:103](.devcontainer/Dockerfile#L103)
- **Evidence:**
  > Dockerfile:103 `playwright install-deps chromium` shells out to `apt-get update && apt-get install` for Chromium's system libraries, but the RUN block (lines 97-106) ends with only `npm cache clean --force` (line 106) — there is no `apt-get clean; rm -rf /var/lib/apt/lists/*` after it, unlike the two dedicated apt layers at lines 56 and 70 which both clean up.
- **Why it matters:** The apt package lists fetched by `install-deps` (tens of MB) are committed into this layer and persist in the final image, since later layers don't (and can't) remove files from an earlier layer's committed size. The two hand-written apt layers correctly clean up; this implicit apt invocation does not, leaving the image larger than necessary.
- **Recommendation:** Append `apt-get clean; rm -rf /var/lib/apt/lists/*` to the RUN at Dockerfile:97-106 (after the playwright steps). If adopting the apt cache-mount from the BuildKit finding, mount `/var/lib/apt/lists` here too so the lists live in the cache instead of the layer.

## Redundant chmod +x on git-tracked 0755 scripts already preserved by COPY

- **Severity / kind:** nit / maintainability
- **Location:** [.devcontainer/Dockerfile:164](.devcontainer/Dockerfile#L164)
- **Evidence:**
  > `git ls-files -s` reports mode 100755 for install-tools.sh, init-firewall.sh, entrypoint.sh, seed-claude.sh, init-cron.sh, crontab-reload, crontab-edit. COPY preserves the source file mode, so these arrive executable. Yet Dockerfile:77 runs `chmod +x /usr/local/bin/install-tools.sh` and Dockerfile:164-169 re-`chmod +x` the six other scripts.
- **Why it matters:** The exec bit is already set by the tracked git mode + COPY, so the chmod calls are no-ops on a normal checkout. They are harmless but add build steps and obscure which lines are actually load-bearing. Note the surrounding `sed 's/\r$//'` CRLF strip in the same RUN (lines 152-163) IS required, so the RUN itself must stay — only the chmod portion is redundant.
- **Recommendation:** Drop the `chmod +x` from Dockerfile:77 (fold install-tools.sh's COPY+chmod into a plain COPY + the existing RUN that already invokes it) and remove lines 164-169's chmod block, keeping the sed CRLF normalization. If you prefer defensiveness against a clobbered host mode, add a one-line comment on the chmod explaining it guards against a non-git context, per the org rule that redundant code carries a justifying comment.
