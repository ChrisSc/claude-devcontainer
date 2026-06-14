# Security Policy

## What this project is

This is a **single-user, local development container** — an isolated home for
Claude Code on your own machine. It is a convenience-and-guardrail sandbox, **not**
a hardened, multi-tenant, or production security boundary. Treat it as you would
any dev container you run locally.

## Security model

- **Default-deny egress firewall.** At startup `init-firewall.sh` builds an
  iptables/ipset allowlist (`FIREWALL_MODE=strict`, the default) so the container
  can only reach an explicit set of hosts (Anthropic, npm, PyPI, GitHub, …). This
  limits what a compromised dependency or a misbehaving agent can fetch or
  exfiltrate. It is a **guardrail, not a guarantee** — allowlisted hosts (GitHub,
  npm, …) can themselves be abused as exfiltration channels.
- **Escape hatches are intentional.** `FIREWALL_MODE=permissive` opens egress
  entirely, and `config/extra-allowlist.txt` widens the allowlist. Whoever runs the
  container controls these.
- **Degraded mode.** On hosts whose kernel lacks iptables/ipset (some WSL2
  kernels), the firewall self-disables and egress is **unrestricted** — by design,
  so the container still boots. A `FIREWALL DEGRADED` banner is printed at startup;
  check it if you depend on filtering being active.
- **Passwordless `sudo` and `NET_ADMIN`.** These are granted so the
  entrypoint can apply the firewall. A process inside the container effectively has
  root *in the container*. The isolation boundary is the container/VM — not the
  in-container user.
- **No host credentials are mounted.** You authenticate (Claude, `gh`, git, ssh)
  *inside* the container; those secrets live in named volumes, not on the host.
- **Scheduled agents (cron) run unattended.** `cron` jobs execute as `claude` with
  the persisted in-container auth (Claude, `gh`, git, ssh) and the same allowlisted
  egress as an interactive session — so a malicious or compromised crontab entry is
  an exfiltration/abuse vector that runs without anyone watching. The crontab source
  of truth (`~/.claude/cron/crontab`) lives in the `~/.claude` volume: it is **not**
  host-editable, but it **is** writable from inside the container, so anything that
  can write that file can schedule unattended jobs.
- **DB secret** is generated locally into the gitignored `.devcontainer/.env`
  (`0600`) and is never committed.

## Explicitly out of scope

- Protecting the host from a malicious base image or a container escape.
- Preventing exfiltration through allowlisted hosts.
- Multi-user or production hardening.

## Reporting a vulnerability

Please report security issues **privately**, not in a public issue:

- Use GitHub's **"Report a vulnerability"** (repository **Security → Advisories →
  private vulnerability reporting**), or
- if advisories are disabled, open a minimal public issue asking for a private
  contact (do not include exploit details).

This is a personal, best-effort project with no formal response SLA, but reports
are genuinely welcome and appreciated.
