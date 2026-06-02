# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- The firewall allowlist is now templated: the repo ships an anonymized
  `config/extra-allowlist.txt.example`, and the real `config/extra-allowlist.txt`
  is **gitignored** (it may hold LAN IPs / private hosts). A host preflight
  (`gen-allowlist.sh`, run by `make up`/`rebuild` and `devcontainer.json`'s
  `initializeCommand`) seeds the real file from the template if missing — required
  because a missing bind-mount source would make Docker create an empty directory
  there and break `init-firewall.sh`. The template keeps `@aws-ip-ranges` active by
  default (the image ships the AWS CLI).

### Security

- Removed personal data from the tracked allowlist (a LAN IP and personal
  financial-data hosts) ahead of making the repo public.

## [0.1.2] - 2026-06-02

### Changed

- SSH persistence now covers `known_hosts` / `known_hosts.old`: `seed-claude.sh`
  symlinks the whole `~/.ssh` dir to the persistent `~/.claude/ssh` volume (instead
  of just the `config` file), so learned host fingerprints survive rebuilds and no
  longer need re-accepting. A directory symlink is required — OpenSSH rewrites
  `known_hosts` via temp-file + atomic rename, which would clobber a per-file
  symlink.

## [0.1.1] - 2026-06-01

### Added

- Firewall allowlist now accepts a bare **IPv4 address or CIDR** (e.g. a LAN host)
  on its own line in `extra-allowlist.txt`, added straight to the ipset. Hostnames
  are still resolved at apply time.
- Financial-data egress hosts (Robinhood, Yahoo Finance, Finviz, Zacks,
  TradingView) to the extra-allowlist.

### Documentation

- README "Network posture" now documents literal IP/CIDR allowlist entries and the
  Docker Desktop macOS inode-pin caveat (edit + re-run reads stale content; restart
  to re-bind the mount).

## [0.1.0] - 2026-06-01

Initial release — a modernized, security-sandboxed dev container that serves as a
self-contained home for Claude Code, derived from Anthropic's official
`.devcontainer`.

### Added

- Multi-arch image (macOS/arm64 + Windows WSL2/amd64), built native to the host —
  no emulation. Node 24 / Debian bookworm base; user `claude` (passwordless sudo),
  zsh + starship.
- Default-deny egress firewall (`init-firewall.sh`) with an expanded allowlist, a
  host-editable `extra-allowlist.txt`, and a `FIREWALL_MODE=permissive` escape
  hatch. Non-fatal per-domain resolver; degrades (rather than bricks) on kernels
  that lack iptables/ipset.
- AWS egress via the published `ip-ranges.json` feed (`@aws-ip-ranges` directive),
  AWS CLI v2 baked into the image, and `~/.aws` / `~/.ssh` persisted across
  rebuilds.
- Language toolchains: TypeScript / pnpm / tsx, Python 3.14 via `uv` + `ruff` +
  `pyright`, Playwright + Chromium baked in. CLI toolbelt (ripgrep, fd, bat, eza,
  zoxide, fzf, jq, yq, delta, gh, lazygit, …).
- Opt-in shared Postgres 18 + pgvector sidecar (`db` compose profile) with a
  generated, injected `.env` secret and pgvector enabled in `template1`.
- `Makefile` shortcuts (`up`, `shell`, `rebuild`, `firewall`, `cp-skill`, the
  `db-*` targets, …) and a VS Code "Reopen in Container" path sharing the same
  compose file.
- MIT license for this repo's original work, `SECURITY.md`, and upstream
  attribution to Anthropic's devcontainer.

[Unreleased]: https://github.com/ChrisSc/devcontainer/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/ChrisSc/devcontainer/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/ChrisSc/devcontainer/releases/tag/v0.1.0
