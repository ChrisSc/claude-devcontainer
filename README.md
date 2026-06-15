# Claude Code Dev Container

[![CI](https://github.com/ChrisSc/claude-devcontainer/actions/workflows/ci.yaml/badge.svg)](https://github.com/ChrisSc/claude-devcontainer/actions/workflows/ci.yaml)
[![Claude Code](https://img.shields.io/badge/Claude_Code-home-D97757?logo=claude&logoColor=white)](https://claude.com/claude-code)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-18-4169E1?logo=postgresql&logoColor=white)](https://www.postgresql.org/)
[![pgvector](https://img.shields.io/badge/pgvector-enabled-2F6792?logo=postgresql&logoColor=white)](https://github.com/pgvector/pgvector)
[![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker&logoColor=white)](https://docs.docker.com/compose/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE.md)

> **Unofficial / not affiliated with Anthropic.** Independent project; derived
> from Anthropic's devcontainer (see [License & attribution](#license--attribution)).

A modernized, security-sandboxed home for [Claude Code](https://claude.com/claude-code),
derived from the official [`anthropics/claude-code/.devcontainer`](https://github.com/anthropics/claude-code/tree/main/.devcontainer).

- **Base:** Node 24 (LTS) on Debian bookworm. Runs on any **arm64 or amd64**
  Docker host — native **Linux**, **macOS**, or **Windows WSL2** — building native
  to the host arch, no emulation (see [Platform support](#platform-support)).
- **User:** `claude` (passwordless sudo), zsh + starship.
- **Languages:** Node 24 / TypeScript / pnpm / tsx, Python 3.14 via `uv` + `ruff`
  + `pyright`, Playwright + Chromium (baked in).
- **Toolbelt:** ripgrep, fd, bat, eza, zoxide, fzf, jq, yq, delta, gh, lazygit,
  bottom, dust, procs, sd, hyperfine, tokei, tldr, …
- **Security:** default-deny egress firewall with an expanded allowlist, a
  host-editable extra-allowlist, and a `FIREWALL_MODE=permissive` escape hatch.
- **Persistence:** named volumes for workspace, Claude config/auth, shell
  history, and the pnpm store.
- **Scheduling:** a persistent crontab + cron daemon for running Claude agents on
  a schedule — jobs live in the `~/.claude` volume and survive rebuilds.

Compose project (container group): **`claude`** · container: **`claude-code`**.

## Platform support

Support is gated on **arch, not OS** — everything runs inside a Linux container,
and the same Dockerfile builds **native to the host arch** (no emulation, no
`--platform` flag) as long as that arch is arm64 or amd64:

| Host | Arch | Notes |
|---|---|---|
| Linux | arm64 / amd64 | Docker Engine. Cleanest host — iptables/ipset are in-kernel, so the firewall runs fully. |
| macOS, Apple Silicon | arm64 | Docker Desktop. Works out of the box. |
| Windows, Intel/AMD | amd64 | Docker Desktop with the **WSL2 backend**, run from inside WSL2. |

**Windows / WSL2 setup (one-time):**

1. Install Docker Desktop and enable **Settings → General → Use the WSL2 based
   engine**, plus **Settings → Resources → WSL Integration** for your distro.
   The WSL2 backend is required — the firewall uses `NET_ADMIN` + iptables/ipset,
   which need the WSL2 Linux kernel; the legacy Hyper-V backend can't load them.
2. **Clone the repo *inside* the WSL2 filesystem** (e.g. `~/claude-sandbox`), not
   under `/mnt/c/...`. The Windows-mounted path loses Unix exec bits and is much
   slower for Docker I/O.
3. Run the same commands as below from your WSL2 shell.

Line endings are forced to LF (`.gitattributes` + a `sed` guard in the
Dockerfile), so a Windows checkout won't corrupt the shell scripts. If you ever
see `bad interpreter: ...^M`, your editor rewrote a script to CRLF — re-checkout
or run `sed -i 's/\r$//'` on it.

## Run it (standalone)

```bash
# build + start (firewall, CLAUDE.md seed, claude auto-update, and cron run on start)
docker compose -f .devcontainer/compose.yaml up -d --build

# drop into an interactive login shell as `claude`
docker exec -it claude-code zsh -l
```

Or use the `Makefile` shortcuts: `make up`, `make shell`, `make rebuild`,
`make logs`, `make stop`, `make down`, `make nuke` (removes volumes),
`make firewall` (re-apply egress rules), `make doctor` (`claude doctor`).

## Run it (VS Code)

Open the folder and **"Reopen in Container"** — `devcontainer.json` references the
same `compose.yaml`, so you get the identical environment with the Claude Code,
ESLint, Prettier, GitLens, Python, Pylance, Ruff, and Playwright extensions
preinstalled.

## Timezone

The container defaults to **`America/New_York`**. The clock itself is the host's
(a container shares the host kernel's time — Docker Desktop keeps its VM synced to
your machine), so only the *zone* is configured here, via the `TZ` variable. It's
set in two places that stay in lockstep: the env var (which glibc CLI tools honor)
and `/etc/localtime` (which everything else reads).

Override it for your region with the `TZ` env var — `compose.yaml` threads it into
both the build arg and the runtime env:

```bash
TZ=Europe/London docker compose -f .devcontainer/compose.yaml up -d --build
# or with the Makefile
TZ=Europe/London make up
```

Use any [IANA zone name](https://en.wikipedia.org/wiki/List_of_tz_database_time_zones)
(e.g. `Asia/Tokyo`, `UTC`). Because the zone is baked into `/etc/localtime` at
build time, a full switch needs a **rebuild** (`--build` / `make rebuild`), not
just a restart. Verify inside the container with `date` (look for the offset, e.g.
`EDT`/`-04:00`). To change the default permanently, edit the `TZ` fallbacks in
`compose.yaml` and the `ARG TZ` in the `Dockerfile`.

## First run

```bash
claude            # authenticate Claude Code
gh auth login     # GitHub auth (persists in the ~/.claude volume)
git config --global user.name  "Your Name"
git config --global user.email "you@example.com"
```

Since `/workspace` is an isolated volume, bring code in by cloning
(GitHub is allowlisted): `git clone https://github.com/you/repo /workspace/repo`.

### SSH for git (push over `git@github.com`)

`gh auth login` already covers HTTPS git. If you'd rather push over SSH, create a
container-only key in the persistent `~/.claude` volume, register it with GitHub,
and wire it into ssh — no ssh-agent needed (the key has no passphrase):

```bash
mkdir -p ~/.claude/ssh && chmod 700 ~/.claude/ssh
ssh-keygen -t ed25519 -C "claude-code container" -f ~/.claude/ssh/id_ed25519 -N ""

# register the public key with GitHub (one-time scope grant, then add)
gh auth refresh -h github.com -s admin:public_key
gh ssh-key add ~/.claude/ssh/id_ed25519.pub --title "claude-code container"

# point ssh at the key (~/.ssh is symlinked to ~/.claude/ssh at boot — see below)
cat > ~/.claude/ssh/config <<'EOF'
Host github.com
  IdentityFile ~/.claude/ssh/id_ed25519
  IdentitiesOnly yes
EOF
chmod 600 ~/.claude/ssh/config

ssh -T git@github.com   # expect: "Hi <user>! You've successfully authenticated…"
```

Everything in `~/.claude/ssh/` persists across rebuilds: `seed-claude.sh` points
`~/.ssh` at it as a directory symlink on every boot, so the key, `config`, and
learned `known_hosts` fingerprints all survive — no manual relinking, and no
re-accepting host fingerprints after a `make rebuild`. The `gh auth refresh` step
uses GitHub's device flow — it prints a code; open the URL on your **host** browser
to approve (the firewall allows `github.com`).

## What persists

Only these **named volumes** survive a rebuild. Everything else in the container
filesystem — including anything you create in `~/` (e.g. a `~/projects` folder) —
survives `stop`/`start` but is **wiped by `make rebuild`** (and `make down`/`up`).

| Path | Volume | Holds |
|---|---|---|
| `/workspace` | `claude-workspace` | your code — put all durable work here |
| `~/.claude` | `claude-config` | Claude state/auth, added skills, `gh`/`git`/`ssh` creds, cron jobs |
| `/commandhistory` | `claude-bashhistory` | shell history |
| `~/.local/share/pnpm` | `claude-pnpm-store` | pnpm content store |

`make nuke` (`down -v`) is the only command that deletes these volumes. Volumes
are not host folders — move code in/out with `git` or `docker cp` (below), not Finder.

## Copying files in and out

The volumes aren't host directories, so you copy across the boundary explicitly.

**Preferred (host -> container): tar-pipe, so files arrive owned by `claude`.**
`docker cp` has no `--chown` and preserves the host's numeric uid/gid (your macOS
`501`), landing files as an unmapped owner you then have to `chown`. Piping a tar
stream into `docker exec -u claude` instead extracts as `claude`, so ownership is
correct in one step -- no `sudo` afterward:

```bash
# Install a skill into the persistent ~/.claude volume, owned by claude
tar -C ~/dev -cf - my-skill | docker exec -i -u claude claude-code \
  tar -C /home/claude/.claude/skills -xf -
```

`-C ~/dev` is the folder's parent on the host, `my-skill` the folder to send, and
`-C /home/claude/.claude/skills` the destination inside the container. macOS tar
may print harmless `LIBARCHIVE.xattr...provenance` warnings -- the files extract
fine. The `make cp-skill SRC=~/dev/my-skill` shortcut wraps this exact command.

**`docker cp` (fine for one-off files; pulling results back out):**

```bash
docker cp ./config.toml claude-code:/workspace/config.toml   # host  -> container
docker cp claude-code:/workspace/out.csv ./out.csv           # container -> host
```

If you do use `docker cp` host -> container, fix the two things it gets wrong:

- **Ownership** -- normalize to `claude` (safe even if already correct):
  ```bash
  docker exec -u root claude-code chown -R claude:claude <dest-path>
  ```
- **Mode is copied verbatim** -- a script that wasn't `+x` on the host arrives
  non-executable (`command not found` under `sudo`). `chmod +x` it on the host
  before copying, or in the container after. See *Troubleshooting the firewall*.

Skills copied to `~/.claude/skills` persist across rebuilds (they live in the
`claude-config` volume) and are picked up the next time you start `claude`.

## Database (Postgres + pgvector)

A shared Postgres 18 + `pgvector` sidecar (`claude-db`) is available so you don't
re-cobble a database per project. It's **opt-in** via the `db` compose profile —
nothing starts unless you ask. The DB commands run the `psql`/`pg_dump` client from
*inside* `claude-code`, so bring the main container up first (`make db-up` only
starts the sidecar, not `claude-code`):

```bash
make up                     # start claude-code (the DB commands exec into it)
make db-up                  # start the sidecar (generates .env on first run)
make db-create DB=myproj    # one DB per project, with pgvector enabled
make db-psql DB=myproj      # interactive psql
make db-dump                # dump all DBs to ./db-backups (survives `make nuke`)
make db-down                # stop it (data volume preserved)
```

- **One server, many databases** — `make db-create DB=<name>` per project instead
  of a container each.
- **pgvector on by default** — `vector` is enabled in `template1`, so the default
  `claude` DB and every database you create (including bare `createdb`) already
  have it. No manual `CREATE EXTENSION`.
- **Access:** from `claude-code` as `db:5432` (credentials are pre-injected as
  `$DATABASE_URL` / `PG*` env vars); from the host at `127.0.0.1:5432` for GUI
  tools like TablePlus/DBeaver.
- **Secret:** a strong password is generated into `.devcontainer/.env` (gitignored,
  `0600`) by `make env`/`db-up` and injected into both containers — never
  committed, never hardcoded. It's baked into the data volume on first init;
  rotating it means `make db-reset` (destroys data). `.env.example` is the tracked
  template.
- **Persistence:** data lives in the `claude-pgdata` volume (survives rebuilds;
  `make nuke`/`make db-reset` destroy it).

## Scheduled agents (cron)

Run Claude agents on a schedule. `cron` is installed and its daemon starts at
boot. The crontab is a **real file in the persistent `~/.claude` volume**
(`~/.claude/cron/crontab`) that's re-installed into the live cron spool on every
boot — so your jobs survive rebuilds.

```bash
make shell
crontab-edit        # edit ~/.claude/cron/crontab in $EDITOR, then auto-apply
crontab -l          # inspect the live spool
make cron-reload    # re-apply after editing the file (run from the host)
make cron-log       # follow job output in ~/.claude/cron/logs
```

A job that runs an agent every morning, appending its output to a log:

```cron
0 9 * * * cd /workspace && claude -p "summarize yesterday's commits" >> ~/.claude/cron/logs/daily.log 2>&1
```

- **Edit the file, not `crontab -e`.** Bare `crontab -e` writes to the ephemeral
  spool and is **lost on rebuild**; `crontab-edit` / `crontab-reload` round-trip
  through the persisted `~/.claude/cron/crontab` (a header in the file reminds you).
- **The environment is handled for you.** cron strips the environment, so each job
  runs via `bash` sourcing `~/.claude/cron/cron.env` (regenerated each boot with
  `CLAUDE_CONFIG_DIR`, `PATH`, auth paths, …). Claude auth comes from the persistent
  `~/.claude`, so `claude -p "…"` runs non-interactively with your existing login.
- **Logs:** cron's own daemon output isn't captured (no syslog) — redirect each job
  to `~/.claude/cron/logs/` as above, then tail with `make cron-log`.
- **Egress:** a job reaching a host beyond the default allowlist needs that host in
  `extra-allowlist.txt` (see [Network posture](#network-posture)), then `make firewall`.
- **Why a file and not a symlink:** Linux's cron refuses symlinked / wrong-permission
  crontabs, so the spool can't just point into a volume — the file is re-installed at
  boot instead. Jobs only run while the container is up.

## Network posture

The firewall is **default-deny outbound**. The host-editable allowlist lives at
`.devcontainer/config/extra-allowlist.txt`. That file is **gitignored** (it may
hold LAN IPs / private hosts); the tracked template is
`extra-allowlist.txt.example`. On your first `make up`/`make rebuild` (or VS Code
"Reopen in Container"), the preflight seeds the real file from the template if it's
missing — the default allows AWS egress (`@aws-ip-ranges`). Edit it to add your
own hosts, then `make firewall`. If something can't reach the network:

- Check the allowlist: `sudo ipset list allowed-domains`.
- Add an entry: put a **hostname** *or* a bare **IPv4 address / CIDR** (e.g. a LAN
  host like `192.168.1.50`) on its own line in
  `.devcontainer/config/extra-allowlist.txt` (mounted at
  `/etc/claude-firewall/extra-allowlist.txt`). Hostnames are resolved at apply
  time; IPs/CIDRs are added straight to the firewall set.
- Apply it: `make firewall`. **On Docker Desktop macOS**, if you edited the file in
  an editor rather than `>>`-appending, the single-file bind mount is inode-pinned
  to the old file — re-running the firewall re-reads stale content and your edit
  appears to do nothing. Run `docker restart claude-code` instead (re-binds the
  mount and re-applies the rules), or `make rebuild` to bake the change in.
- Open egress entirely: re-create the container in permissive mode —
  `FIREWALL_MODE=permissive docker compose -f .devcontainer/compose.yaml up -d --force-recreate`.
  `FIREWALL_MODE` is read at container *create* time, so a plain `up -d` or `restart`
  on an already-running container won't switch it.

## Troubleshooting the firewall

**Symptom: `no route to host` / `connect: Timeout` to a host, but DNS resolves.**
That's the firewall's `REJECT` rule — the destination IP isn't in the
`allowed-domains` ipset. `dig` works (DNS to the container's resolver is allowed)
while `:443` connects fail. Fix by allowlisting the host (see Network posture) and re-running
`make firewall`.

**Symptom: `make firewall` itself times out fetching `api.github.com/meta`**, and
afterwards GitHub (and anything covered by GitHub's IP ranges) is unreachable.
This was a bug fixed in `init-firewall.sh`: `iptables -F` flushes rules but *not*
the default policy, so a re-run inherited the previous run's `OUTPUT DROP` and
blocked its own bootstrap fetch. The script now resets policies to `ACCEPT`
during reconfiguration and clamps back to `DROP` at the end. If you see this on
an **old running container** (started before the fix), push the current script in
and re-run:

```bash
docker cp .devcontainer/init-firewall.sh claude-code:/usr/local/bin/init-firewall.sh
docker exec -u root claude-code chmod +x /usr/local/bin/init-firewall.sh   # cp drops the exec bit
make firewall
```

A successful run ends with `verified: api.github.com is reachable`. To make the
fix permanent, `make rebuild`.

**Gotcha: `sudo: /usr/local/bin/init-firewall.sh: command not found`** after a
`docker cp` means the copied file lost its execute bit (host scripts must be
`+x`). Restore it with the `chmod +x` line above; the repo keeps these scripts
executable so future copies carry the bit.

**Intermittent download failures** (pip/uv/playwright) usually mean a CDN rotated
to an IP not captured at boot. Re-run `make firewall` to refresh the resolved IPs.

## Layout

```
.devcontainer/
  devcontainer.json    compose.yaml    Dockerfile
  init-firewall.sh     entrypoint.sh   seed-claude.sh    install-tools.sh
  log-event.sh         # boot-event JSONL trail (sourced by the startup scripts)
  init-cron.sh         crontab-reload  crontab-edit      # scheduled agents (cron)
  gen-env.sh           gen-allowlist.sh   db-init/10-pgvector.sql
  config/extra-allowlist.txt.example    .env.example   # real files generated, gitignored
  home/.zshrc          home/.config/{starship.toml,zsh/aliases.zsh}
  seed/CLAUDE.md       seed/crontab    # seeded into ~/.claude/ on first start
```

See `.devcontainer/seed/CLAUDE.md` for the in-container orientation doc.

## License & attribution

This repository's own original work is licensed under the [MIT License](LICENSE.md).

It is **derived from** Anthropic's
[`anthropics/claude-code/.devcontainer`](https://github.com/anthropics/claude-code/tree/main/.devcontainer) —
most directly `init-firewall.sh` (the default-deny egress pattern). That upstream
project is **not** open source; it is governed by
[Anthropic's Commercial Terms of Service](https://www.anthropic.com/legal/commercial-terms).
The MIT grant here covers only this repo's original code; the derived portions
remain subject to Anthropic's terms. If you redistribute, keep this attribution.

**Not affiliated with Anthropic.** This is an independent, unofficial project — not
endorsed by or sponsored by Anthropic. "Claude" and "Claude Code" are trademarks of
Anthropic, PBC, used here only to describe what this container runs.

See [SECURITY.md](SECURITY.md) for the sandbox's security model and how to report issues.
