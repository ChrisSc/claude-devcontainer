# docs-accuracy — audit findings

Overall the documentation is detailed and largely faithful to the code, but it lags the most recent feature work and carries a handful of small accuracy drifts. The highest-impact gap is the security model (`SECURITY.md`) never being updated for the v0.1.5 cron / scheduled-agents feature, leaving an autonomous, network-capable, credential-bearing execution path undocumented in the threat surface. The remaining findings are operational and copy-level: an in-container instruction that tells the agent to "restart" for permissive mode (which a plain restart cannot change), an installed-and-hooked `direnv` documented nowhere, a missing `--force-recreate` caveat the repo documents elsewhere, a dropped "not" that inverts a diagnostic sentence, and a two-vs-three timezone-location miscount. None of the lower findings reflect broken behavior — they reflect docs that mislead the reader who acts on them.

## SECURITY.md predates the cron / scheduled-agents feature and omits it from the security model

- **Severity / kind:** medium / security
- **Location:** [SECURITY.md:11](SECURITY.md#L11)
- **Evidence:**
  > SECURITY.md was last modified 31 May; the cron feature landed in v0.1.5 on 9 Jun (CHANGELOG.md:10-22, commit 1a335c7). `rg -ni 'cron|schedul' SECURITY.md` returns nothing. Yet the feature runs `claude -p "..."` jobs unattended on a schedule with full egress and persisted auth (init-cron.sh; seed/CLAUDE.md §10; README §"Scheduled agents"). The 'Security model' (SECURITY.md:11-32) and 'Explicitly out of scope' (SECURITY.md:34-38) sections describe only the firewall, sudo, and credential posture.
- **Why it matters:** Scheduled agents are a material change to the threat surface: cron jobs execute autonomously (no interactive human), inherit the persisted `~/.claude` auth, and have the same allowlisted egress that SECURITY.md already flags as an exfiltration channel. A security-model doc that omits an autonomous, network-capable, credential-bearing execution path is materially incomplete and will mislead anyone assessing the sandbox.
- **Recommendation:** Add a bullet to SECURITY.md 'Security model' noting that cron jobs run unattended as `claude` with persisted auth and the same allowlisted egress (so a malicious crontab entry is an exfiltration/abuse vector), and that the crontab source of truth (`~/.claude/cron/crontab`) is host-uneditable but in-container-writable. Reconcile against the v0.1.5 cron addition.

## seed/CLAUDE.md tells the agent to 'restart' for permissive mode, but a plain restart can't change FIREWALL_MODE

- **Severity / kind:** medium / docs
- **Location:** [.devcontainer/seed/CLAUDE.md:36](.devcontainer/seed/CLAUDE.md#L36)
- **Evidence:**
  > seed/CLAUDE.md:36-37 says: "**Open the web entirely:** restart with `FIREWALL_MODE=permissive`". But FIREWALL_MODE is supplied by compose at container *create* time (compose.yaml:32 `FIREWALL_MODE: ${FIREWALL_MODE:-strict}`), and the project CLAUDE.md:152 itself documents the analogous `.env` case: "a plain `restart` re-reads nothing" → "Fix is `--force-recreate`". A `docker restart claude-code` re-runs the entrypoint but keeps the *existing* container's baked-in `FIREWALL_MODE=strict`, so the agent's instruction silently fails to open egress.
- **Why it matters:** An in-container agent following this verbatim will run something like `docker restart` (or expect a host restart to honor a new value) and conclude permissive mode is broken, because the env var is fixed at create time. The README's own command (README.md:293) correctly uses `docker compose ... up -d` (which recreates on env change), so the seed doc is the outlier and is actively misleading to the audience most likely to act on it.
- **Recommendation:** Reword seed/CLAUDE.md:36 to point at the host-side recreate, e.g. "ask the host operator to re-create the container with `FIREWALL_MODE=permissive docker compose ... up -d --force-recreate`" — and note that a bare `docker restart` will NOT change the mode (it is fixed at container create time).

## direnv is installed and shell-hooked but documented nowhere

- **Severity / kind:** low / docs
- **Location:** [README.md:21](README.md#L21)
- **Evidence:**
  > Dockerfile:45 installs `direnv` in the apt block; home/.zshrc:36 runs `command -v direnv >/dev/null && eval "$(direnv hook zsh)"`. README toolbelt (README.md:21-22) lists `ripgrep, fd, bat, eza, zoxide, fzf, jq, yq, delta, gh, lazygit, bottom, dust, procs, sd, hyperfine, tokei, tldr` but NOT direnv. seed/CLAUDE.md:62-70 (the in-container tool inventory) also omits it. `rg direnv README.md CLAUDE.md seed/CLAUDE.md` returns nothing.
- **Why it matters:** direnv is a non-trivial, user-facing capability: a `.envrc` in a project directory is auto-loaded into the interactive shell. A user (or Claude itself) reading the env docs has no way to know `.envrc` auto-loading is active, so they won't use it and may be surprised when an `.envrc` silently takes effect. Every other interactively-hooked tool (zoxide, starship, fzf) is documented.
- **Recommendation:** Add `direnv` to the README toolbelt line (README.md:21-22) and to the seed/CLAUDE.md §4 "Git/dev" or a new "Env" bullet (seed/CLAUDE.md:62-70), noting that `.envrc` files in a directory are auto-loaded in interactive shells.

## README 'Open egress entirely' omits the --force-recreate caveat its own CLAUDE.md documents

- **Severity / kind:** low / docs
- **Location:** [README.md:293](README.md#L293)
- **Evidence:**
  > README.md:293 gives `FIREWALL_MODE=permissive docker compose -f .devcontainer/compose.yaml up -d` for opening egress. compose `up -d` only re-creates the container when it detects the env change, and the project CLAUDE.md:151-152 explicitly warns that for env-var changes "a plain `restart` re-reads nothing" and "Fix is `--force-recreate`". The mode-file stickiness (init-firewall.sh:24-28, MODE_FILE) further means that once a container has recorded `permissive`, a later bare firewall re-run stays permissive — useful context the README never states.
- **Why it matters:** If a user has an already-running strict container and runs the README command, compose usually recreates (because the env changed) — but the behavior is subtle and the README gives no fallback if it doesn't take effect. Surfacing `--force-recreate` (already the documented fix elsewhere in the repo) makes the instruction robust and consistent with CLAUDE.md:152.
- **Recommendation:** Append `--force-recreate` to the README.md:293 command (or add a one-line note: "add `--force-recreate` if the container already exists"), matching the guidance in CLAUDE.md:151-152.

## seed/CLAUDE.md CDN-rotation note drops the word 'not', inverting its meaning

- **Severity / kind:** low / docs
- **Location:** [.devcontainer/seed/CLAUDE.md:39](.devcontainer/seed/CLAUDE.md#L39)
- **Evidence:**
  > seed/CLAUDE.md:39 reads: "usually mean a CDN rotated to an IP captured-at-boot." The intended meaning (and the correct phrasing in README.md:326-327: "a CDN rotated to an IP not captured at boot") is the opposite — the failure is the IP was NOT among those resolved at boot. As written, "rotated to an IP captured-at-boot" describes the *working* case, so the sentence contradicts the symptom it is explaining.
- **Why it matters:** The in-container doc is the one an agent consults when egress fails; the inverted sentence describes the non-problem, undercutting the (otherwise correct) advice to re-run the firewall. It's a one-word omission but it reverses the diagnostic logic.
- **Recommendation:** Change seed/CLAUDE.md:39 to "...rotated to an IP **not** captured at boot." to match README.md:326-327.

## README timezone section says TZ is set in 'two places' but the build writes three (env, /etc/localtime, /etc/timezone)

- **Severity / kind:** nit / docs
- **Location:** [README.md:86](README.md#L86)
- **Evidence:**
  > README.md:86-87: "It's set in two places that stay in lockstep: the env var ... and `/etc/localtime`". The Dockerfile actually writes THREE: `ENV TZ` (Dockerfile:18), `/etc/localtime` (Dockerfile:51), and `/etc/timezone` (Dockerfile:52). The project CLAUDE.md describes "`TZ` lives in three places that must agree" (counting the compose threading instead). README and CLAUDE.md give different counts.
- **Why it matters:** Minor, but the README undercounts the system files it configures (`/etc/timezone` is written and read by some tooling), and the 'two vs three places' mismatch with CLAUDE.md can confuse a maintainer reconciling the docs. Not a behavioral bug.
- **Recommendation:** Either say "the env var plus the system files (`/etc/localtime` + `/etc/timezone`)" at README.md:86, or explicitly scope the count as "two things inside the container" to distinguish it from CLAUDE.md's compose-threading 'three places'.
