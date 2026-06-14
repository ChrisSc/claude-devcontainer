# idempotency — audit findings

The firewall reconfiguration path is internally idempotent only when invocations are serialized; nothing enforces that serialization. A single medium-severity bug was found: concurrent `init-firewall.sh` runs (boot entrypoint vs. `make firewall` / VS Code `postStartCommand`) race on kernel-global singletons (the `allowed-domains` ipset, the `OUTPUT` policy) with no lock, and can leave egress half-configured or wide open. No critical or high findings were identified.

## Concurrent init-firewall.sh invocations race on the global allowed-domains ipset and can leave egress broken or open

- **Severity / kind:** medium / bug
- **Location:** [.devcontainer/init-firewall.sh:170](.devcontainer/init-firewall.sh#L170)
- **Evidence:**

  The script mutates kernel-global singletons by fixed name with no lock:

  ```sh
  ipset destroy allowed-domains 2>/dev/null || true   # line 170
  ipset create allowed-domains hash:net               # line 202
  iptables -P OUTPUT ACCEPT                            # line 180
  ```

  Two call sites can fire close together: `entrypoint.sh:22` runs it at boot, while `Makefile:33` (`make firewall`) and `devcontainer.json:56` (`postStartCommand`) re-run it on demand / on the VS Code path.

- **Why it matters:** There is no flock/PID guard. If an operator runs `make firewall` (or VS Code fires `postStartCommand`) while the entrypoint firewall is still executing on a slow boot, run A's `ipset create allowed-domains` collides with run B's `ipset destroy allowed-domains` mid-populate: one side errors out (errors are swallowed by `|| true` / `2>/dev/null`), leaving a half-filled set, OR run B sets `iptables -P OUTPUT ACCEPT` (line 180) and is then killed/over-taken before re-clamping to DROP (line 300), leaving egress OPEN. The script is internally idempotent only when serialized; nothing enforces serialization.
- **Recommendation:** Wrap the body in an flock on a fixed path (e.g. `exec 9>/run/claude-firewall.lock; flock 9`) so overlapping boot+manual invocations serialize. This also protects the `__fw_probe` and mode-file writes.
