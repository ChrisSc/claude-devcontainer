# cron — audit findings

The cron subsystem is structurally sound — the persisted-crontab-into-spool design, the root-via-`sudo` daemon start with a `pgrep` double-start guard, and the per-boot `cron.env` regeneration are all well-considered. The one substantive issue is a functional gap: the environment reconstructed for cron jobs omits every Postgres connection variable, directly contradicting the in-container docs that promise DB access "just works" inside scheduled jobs. There is also a minor latent footgun where `PATH` is set in two places, with one silently overriding the other.

## Cron jobs cannot reach the Postgres DB: cron.env omits all PG*/DATABASE_URL vars that the docs promise are present

- **Severity / kind:** high / bug
- **Location:** [`.devcontainer/init-cron.sh:50`](.devcontainer/init-cron.sh#L50)
- **Evidence:**

```bash
CRON_ENV_VARS=(
    PATH HOME
    CLAUDE_CONFIG_DIR GH_CONFIG_DIR GIT_CONFIG_GLOBAL
    AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE
    PNPM_HOME NODE_OPTIONS TEALDEER_CACHE_DIR
    NPM_CONFIG_PREFIX PLAYWRIGHT_BROWSERS_PATH
    LANG LC_ALL TZ EDITOR VISUAL
)   # note: no PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE/DATABASE_URL
```

- **Why it matters:** compose injects the DB connection env (`PGHOST=db`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`, `PGPORT`, `DATABASE_URL`) into the `claude-code` container via `env_file: .env` (`compose.yaml:27-28`, vars listed in `.env.example:13-18`). `seed/CLAUDE.md` §9 (line 142) explicitly tells the user these creds are "already in the environment, so psql / pg_dump / client libraries auto-connect", and §10 (line 167) promises cron jobs that "Environment is handled for you". But `init-cron.sh` regenerates `cron.env` from this fixed allowlist, which captures NONE of the PG* / DATABASE_URL vars. cron strips the environment, so a scheduled `claude -p` agent (or any psql/pg_dump job) sources `cron.env`, sees no PGHOST/PGPASSWORD/DATABASE_URL, and psql silently falls back to the local unix socket → connection fails. The exact same command works in an interactive shell, so the failure is confusing and only surfaces at job-run time. This is a real functional gap between the cron env reconstruction and the documented DB-access story.
- **Recommendation:** Add the DB client vars to the `CRON_ENV_VARS` allowlist: append `PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE DATABASE_URL` (the `if [ -n "${!name:+x}" ]` guard already skips them harmlessly when the db profile isn't running). Capturing PGPASSWORD/DATABASE_URL into `cron.env` is consistent with the existing security posture (single-user box, `cron.env` is chmod 600 owned by `claude`, same secret already sits in the live env and in `~/.claude`). Alternatively, if DB-in-cron is intentionally unsupported, fix `seed/CLAUDE.md` §10 to state that DB env is NOT propagated to cron and jobs must export PG*/DATABASE_URL themselves.

## cron.env re-exports PATH, double-sourcing it on top of the crontab's own PATH= line

- **Severity / kind:** nit / maintainability
- **Location:** [`.devcontainer/init-cron.sh:51`](.devcontainer/init-cron.sh#L51)
- **Evidence:**

```bash
CRON_ENV_VARS=(
    PATH HOME ...   # PATH captured here AND set literally in seed/crontab:22
```

- **Why it matters:** PATH is set in two places for every job: the crontab's `PATH=` assignment (`seed/crontab:22`), which cron exports into the job environment, and again inside `cron.env` (captured by `CRON_ENV_VARS`), which bash sources via `BASH_ENV` and which therefore OVERRIDES the crontab PATH at job start. The two strings are byte-identical today (both copied from the normalized PATH), so there is no current effect. But it is a latent footgun: a future edit to the crontab's `PATH=` line (e.g. a user prepending a tool dir) would be silently clobbered by the captured `cron.env` PATH, which wins because `BASH_ENV` is sourced after cron sets the crontab variables.
- **Recommendation:** Drop PATH from `CRON_ENV_VARS` (let the crontab's `PATH=` line be the single source of truth, which is the conventional cron idiom), OR drop the `PATH=` line from `seed/crontab` and rely solely on `cron.env`. Keeping both with one silently overriding the other is the kind of duplication the project's own style guidance warns against.
