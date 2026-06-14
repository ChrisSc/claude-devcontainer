# docs — audit findings

The documentation set is broadly accurate and unusually rich in
invariant-level detail, but it has two medium-severity consistency gaps where
guidance is incomplete or contradicts itself across files. The in-container
agent-facing seed doc and the allowlist template omit the Docker Desktop macOS
inode-pin caveat that the human-facing README documents prominently, producing
contradictory instructions about how to refresh the firewall allowlist. The
README's Database quickstart presents a command sequence that silently assumes
the `claude-code` container is already running. Both findings are fixable with
small doc edits; neither indicates a defect in the container itself.

## In-container seed/CLAUDE.md tells the agent to edit the host allowlist then re-run the firewall, omitting the Docker Desktop macOS inode-pin caveat the README does document

- **Severity / kind:** medium / docs
- **Location:** [.devcontainer/seed/CLAUDE.md:31](.devcontainer/seed/CLAUDE.md#L31)
- **Evidence:**

  ```
  - **Add a domain:** append a hostname to `/etc/claude-firewall/extra-allowlist.txt` (editable from the host), then `sudo /usr/local/bin/init-firewall.sh`.
  ```

- **Why it matters:** This is the doc the in-container Claude agent reads (it
  is seeded to `~/.claude/CLAUDE.md`). It instructs: edit the host file, then
  re-run `init-firewall.sh` — with no mention that on Docker Desktop macOS the
  single-file bind mount is inode-pinned, so an editor that replaces the file
  (write-temp + rename) leaves the container reading the STALE inode and the
  re-run reads old content. The repo's CLAUDE.md and README.md:288-292 both
  flag this prominently ('re-running the firewall re-reads stale content and
  your edit appears to do nothing. Run `docker restart claude-code` instead').
  The README's `extra-allowlist.txt.example` header (lines 4-6) has the same
  omission. The result is contradictory guidance across the doc set: the
  human-facing README warns about the inode trap, but the agent-facing seed doc
  and the template header silently tell you to do the thing that fails on the
  project's primary documented platform (Apple Silicon).
- **Recommendation:** Add the inode-pin caveat (restart the container, or `make
  rebuild`, instead of relying on a re-run after an editor save) to
  seed/CLAUDE.md §2's 'Add a domain' bullet and to the
  extra-allowlist.txt.example header, matching README.md's Network-posture
  wording.

## README DB quickstart implies `make db-up` is enough before `make db-create`/`db-psql`, but those exec into `claude-code`, which `db-up` never starts

- **Severity / kind:** medium / docs
- **Location:** [README.md:214](README.md#L214)
- **Evidence:**

  ```
  make db-up                  # start the sidecar (generates .env on first run)
  make db-create DB=myproj    # one DB per project, with pgvector enabled
  make db-psql DB=myproj      # interactive psql
  ```

- **Why it matters:** The README presents these as a sequential quickstart
  under 'It's opt-in ... nothing starts unless you ask.' But Makefile:60
  `db-up` runs `$(COMPOSEDB) up -d db`, which starts ONLY the `db` sidecar — it
  has no dependency on the `claude-code` container and does not start it. Yet
  Makefile:74-76 `db-create` runs `docker exec claude-code createdb ...` /
  `docker exec claude-code psql ...`, and Makefile:67 `db-psql` runs `docker
  exec -it claude-code psql ...` — all of which require the `claude-code`
  container to be running. A user who follows the documented DB section in
  isolation (without first running `make up`) hits `Error: No such container:
  claude-code` (or `is not running`). The psql/createdb client lives in the
  `claude-code` image, not the `db` image, so this routing is intentional — but
  the docs never state the precondition that `claude-code` must already be up.
- **Recommendation:** Add a one-line precondition to the Database section: 'the
  DB commands run the psql/pg_dump client from inside `claude-code`, so bring
  the main container up first (`make up`).' Optionally make
  `db-up`/`db-create`/`db-psql` depend on the container being running (or start
  it), so the documented sequence works standalone.
