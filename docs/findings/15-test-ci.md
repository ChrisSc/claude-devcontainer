# test-ci — audit findings

The repository has **no automated validation whatsoever**: no CI pipeline, no test/smoke harness, no lint gates (shellcheck, hadolint, yamllint), and no guard for the two most-documented break modes (CRLF line endings, lost exec bits). This is notable because the deliverable *is* a Docker image plus a set of `set -euo pipefail` shell scripts, and CLAUDE.md catalogs roughly twenty load-bearing, silently-breakable invariants. The good news is that the code is already clean today — shellcheck, hadolint, and yamllint all pass at warning severity, and `docker compose config` validates — so every recommended gate is cheap to add and would catch regressions only, not flag existing debt. All six findings are gap-type (missing checks) rather than active bugs: four medium, two low.

## No build/boot smoke test — image-breaking changes are invisible until a manual `make rebuild`

- **Severity / kind:** medium / test-gap
- **Location:** [`.github/workflows/ci.yaml`](.github/workflows/ci.yaml)
- **Evidence:**
  > No test harness anywhere (`git ls-files` shows no test/smoke files; Makefile `.PHONY` has up/shell/rebuild/firewall/doctor but no `test`/`check`/`ci`). CLAUDE.md states 'the deliverable is the image and its startup behavior', yet nothing exercises a build or boot.
- **Why it matters:** Lint catches syntax; only an actual build+boot catches wiring regressions the invariants warn about: a Dockerfile COPY that drops an exec bit, a volume that shadows a baked file, the entrypoint ordering, `python3`/`uv` shim resolution, or a firewall that bricks instead of degrading. This is the gate the user's own global standard ('build the project, run the CLI command ... live exercise proves wiring') asks for.
- **Recommendation:** Add a `smoke` CI job (and matching `make smoke`) on `ubuntu-latest` (has Docker): `docker compose -f .devcontainer/compose.yaml build`, then `up -d` with `FIREWALL_MODE=permissive` (CI runners lack NET_ADMIN/ipset for strict), then assert via `docker exec`: `claude --version`, `python3 --version` resolves to the uv 3.14 shim (not /usr/bin 3.11), `command -v rg fd bat jq yq aws lazygit`, and that seeded `~/.claude/ENVIRONMENT.md` exists. Even build-only would catch most breakage.

## No CI pipeline: a GitHub-hosted repo with zero automated validation on push/PR

- **Severity / kind:** medium / test-gap
- **Location:** [`.github/workflows/ci.yaml`](.github/workflows/ci.yaml)
- **Evidence:**
  > `origin git@github.com:ChrisSc/devcontainer.git` is the remote, yet `ls .github/` => "no .github dir" and `git ls-files` lists no workflow files. PR #4 (cron) and PR #2 history show a PR-based flow with no gate.
- **Why it matters:** Every change to the firewall, Dockerfile, compose, or entrypoint lands with no automated check. CLAUDE.md documents ~20 load-bearing invariants (CRLF=LF, FIREWALL_MODE stickiness, exec bits, OUTPUT-policy reset) — all silently breakable and currently caught only by a human remembering to rebuild and boot. The repo is on GitHub, so Actions is free and zero-infra.
- **Recommendation:** Add `.github/workflows/ci.yaml` running on push + pull_request with three cheap jobs (no Docker daemon needed): (1) shellcheck via `ludeeus/action-shellcheck` over `.devcontainer/*.sh` + `crontab-edit`/`crontab-reload`; (2) hadolint via `hadolint/hadolint-action` on `.devcontainer/Dockerfile`; (3) yamllint on `.devcontainer/compose.yaml`. All three are seconds-long; verified green today at `--severity=warning`, so it gates regressions only.

## No hadolint gate; Dockerfile masks installer-download failures (DL4006) on the uv and Claude installs

- **Severity / kind:** medium / test-gap
- **Location:** [`.devcontainer/Dockerfile:201`](.devcontainer/Dockerfile#L201)
- **Evidence:**
  > `hadolint - < .devcontainer/Dockerfile` reports DL4006 at line 201 (`curl -LsSf https://astral.sh/uv/install.sh | sh`) and line 207 (`RUN curl -fsSL https://claude.ai/install.sh | bash`). There is no `SHELL` directive, so RUN uses default `/bin/sh` (dash) without `pipefail`.
- **Why it matters:** Without pipefail, if curl fails (network blip, 404 after an upstream URL change) the pipeline exit status is only the shell's, so a failed download of the uv or Claude Code installer can let `docker build` SUCCEED with a broken/absent install — exactly the silent rot CI should catch. hadolint also flags DL3008/DL3016 (unpinned apt/npm), which are intentional here (rolling-latest image) and should be explicitly suppressed rather than silently ignored.
- **Recommendation:** Add a `.hadolint.yaml` at repo root: `ignored: [DL3008, DL3016, DL3018]` with a comment that latest-pinning is deliberate. Then fix the real DL4006 finding by adding `SHELL ["/bin/bash", "-o", "pipefail", "-c"]` before the curl|sh RUN blocks (or rewrite as download-then-run), and run hadolint in CI so future Dockerfile edits are gated.

## No shellcheck gate despite 9 set-euo-pipefail shell scripts being the core deliverable

- **Severity / kind:** medium / test-gap
- **Location:** [`.devcontainer/init-firewall.sh`](.devcontainer/init-firewall.sh)
- **Evidence:**
  > 9 scripts (entrypoint.sh, init-firewall.sh 329 lines, init-cron.sh, seed-claude.sh, gen-allowlist.sh, gen-env.sh, install-tools.sh, crontab-edit, crontab-reload) and `command -v shellcheck` => NOT INSTALLED, no `.shellcheckrc`. Running `koalaman/shellcheck:stable --severity=warning` over all of them exits 0 with no output.
- **Why it matters:** The deliverable IS these scripts. shellcheck catches the exact class of bug this repo is most exposed to: unquoted expansions in firewall/IP parsing, `set -e` interactions, masked pipe failures. The code is already clean at warning level, so a gate costs nothing now and prevents the next quoting/word-splitting regression in the firewall from shipping.
- **Recommendation:** Add a `.shellcheckrc` at repo root pinning the gate (`severity=warning`, `disable=SC1091`), then wire shellcheck into the CI workflow and a `make lint` target. The only info-level findings today are SC1091 (sourcing /etc/os-release in seed-claude.sh:53), SC2016 and SC2020 (init-firewall.sh:146,148) — all benign/intentional and already excluded by `severity=warning`.

## No automated guard that scripts stay executable + LF — the two most-documented break modes

- **Severity / kind:** low / test-gap
- **Location:** [`.gitattributes:5`](.gitattributes#L5)
- **Evidence:**
  > CLAUDE.md repeatedly warns CRLF breaks the entrypoint (`bad interpreter: ...^M`) and that `docker cp` / lost exec bits cause `sudo: command not found`. `.gitattributes` enforces `eol=lf` at checkout and the Dockerfile does a defensive `sed 's/\r$//'` (line 152), but nothing FAILS a PR that commits a CRLF file or clears an exec bit. Files are `+x` in git today but that is unenforced.
- **Why it matters:** These are the exact regressions the invariants call out as silent and host-specific (only bite on a Windows checkout / after a docker cp). A 5-line CI check makes them unmergeable, independently of whether the Dockerfile's belt-and-suspenders sed is later trimmed.
- **Recommendation:** Add a tiny `check-scripts` CI step (and `make check-scripts`): fail if `git ls-files --eol` reports CRLF on any tracked text file, and fail if any of `.devcontainer/*.sh`, `init-*.sh`, `seed-claude.sh`, `crontab-edit`, `crontab-reload` lacks the git exec bit (`git ls-files -s | awk '$1 !~ /755$/'`). No new dependency — pure git/awk.

## No yamllint gate; compose.yaml missing the document-start marker yamllint flags by default

- **Severity / kind:** low / test-gap
- **Location:** [`.devcontainer/compose.yaml:1`](.devcontainer/compose.yaml#L1)
- **Evidence:**
  > `command -v yamllint` => NOT INSTALLED; no `.yamllint`. compose.yaml line 1 is `# docker compose ...` with no `---` document start (`head -1 | grep '^---'` => NO). `docker compose config --quiet` succeeds, so the file is valid — but structural/style drift is unguarded.
- **Why it matters:** compose.yaml and devcontainer.json carry several load-bearing, easy-to-typo settings (the `:ro` allowlist bind-mount, `PGHOST: ""`, `PGDATA` subdir, `$${...}` escaping in the healthcheck, `cap_add`). A YAML gate plus `docker compose config` is a cheap structural check; yamllint's default profile warns on the missing `---` and any future indentation/duplicate-key slip.
- **Recommendation:** Add a `.yamllint` at repo root (relax `line-length`, set `document-start: {present: false}` to match the current style, or add `---` to compose.yaml), then run `yamllint .devcontainer/compose.yaml` and `docker compose -f .devcontainer/compose.yaml config --quiet` in CI. The config-validate step alone catches the most consequential compose regressions.
