# boot-order — audit findings

The boot sequence is largely sound — ordering is deliberate and load-bearing (firewall before update before cron before `exec "$@"`), and the non-fatal/`pgrep`-guarded design correctly prevents double-starts and hard failures. Two issues remain, both on the network-dependent middle of the critical path: a medium-severity gap where `claude update` runs unbounded with stdin attached (a hang there wedges the rest of boot, including `exec "$@"`), and a low-severity reporting weakness where the cron daemon start always looks successful because Vixie cron daemonizes and returns 0. Neither corrupts state, but the first can stall the container indefinitely and the second can make the boot log lie about cron liveness.

## claude update has no timeout/stdin redirect; a hung update can stall boot before exec "$@"

- **Severity / kind:** medium / bug
- **Location:** [.devcontainer/entrypoint.sh:34](.devcontainer/entrypoint.sh#L34)
- **Evidence:**
  ```
  claude update || echo "[entrypoint] WARN: claude update failed (non-fatal)" >&2
  ```
  No timeout wrapper, no `< /dev/null`. Confirmed by `rg -n 'timeout|< /dev/null' entrypoint.sh` returning nothing.
- **Why it matters:** Step 3 runs synchronously *before* step 4 (cron) and step 5 (`exec "$@"`). `|| echo ...` only catches a non-zero EXIT; it does nothing for a HANG. If `claude update` blocks (a half-open TCP to downloads.claude.ai whose CDN IP rotated out of the boot-captured allowlist, a stuck CDN socket, or any future interactive prompt reading stdin), the entrypoint never reaches `exec "$@"`. The container then sits in 'Created/starting' indefinitely: cron never starts, `sleep infinity` never execs, and `docker exec` works but the lifecycle looks wedged. The firewall (step 1) is the documented mitigation for reachability, but a connect that opens then stalls (vs. is REJECTed) still blocks. This is the single longest-latency, network-dependent, non-essential step sitting on the critical boot path with no deadline.
- **Recommendation:** Bound it and detach stdin: `timeout 120 claude update < /dev/null || echo '[entrypoint] WARN: claude update failed/timed out (non-fatal)' >&2`. The auto-update is explicitly non-essential (postStartCommand and `claude update` re-run it), so a timeout is strictly safer than an unbounded blocking call on the boot path.

## init-cron cannot reliably detect a failed cron daemon start because `sudo -n cron` backgrounds and returns 0

- **Severity / kind:** low / bug
- **Location:** [.devcontainer/init-cron.sh:88](.devcontainer/init-cron.sh#L88)
- **Evidence:**
  ```
  elif sudo -n "$CROND_BIN"; then log "started cron daemon"
  ```
  `$CROND_BIN` is `/usr/sbin/cron` invoked with NO `-f`. Debian Vixie cron double-forks/daemonizes by default, so the parent exits 0 essentially always once it has forked.
- **Why it matters:** The boot step is correctly non-fatal and the `pgrep -x cron` guard correctly prevents the entrypoint + postStartCommand double-start. But the success/failure reporting is unreliable: because cron daemonizes, `sudo -n cron` returns 0 as soon as the fork succeeds, so the `else -> 'could not start cron daemon'` branch only fires if the *exec itself* fails (e.g. binary missing — already screened by the line 29 preflight) or sudo is denied. A daemon that forks and then dies (bad spool perms, /var/run issue) is reported as 'started cron daemon'. The log line is thus near-cosmetic; liveness must be confirmed out-of-band (CLAUDE.md §10 'Liveness: pgrep -x cron'). This does not break boot — it just means the boot log can claim cron started when it did not.
- **Recommendation:** After the start, re-probe before logging success: `elif sudo -n "$CROND_BIN"; then sleep 0 ; pgrep -x cron >/dev/null 2>&1 && log 'started cron daemon' || warn 'cron exited immediately after start'`. (Avoid `cron -f` here — foreground would block the entrypoint before `exec "$@"`.)
