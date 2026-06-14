# config — audit findings

The configuration surface is largely sound, but it carries one high-severity security inconsistency between its two startup entry paths. The CLI path (`entrypoint.sh`) treats a firewall failure as fatal and refuses to start the container, while the VS Code path (`devcontainer.json` `postStartCommand`) silently swallows the same failure due to shell operator precedence — so VS Code can open a workspace with the egress firewall absent and the user unaware. There is one finding, detailed below.

## postStartCommand swallows firewall failure (`A && B; C || true`)

- **Severity / kind:** high / security
- **Location:** [.devcontainer/devcontainer.json:56](.devcontainer/devcontainer.json#L56)
- **Evidence:**

  ```json
  "postStartCommand": "sudo FIREWALL_MODE=${FIREWALL_MODE:-strict} /usr/local/bin/init-firewall.sh && claude update; /usr/local/bin/init-cron.sh || true"
  ```

- **Why it matters:** The command is structured as `A && B ; C || true`. The `;` terminates the firewall+update group, and the trailing `|| true` only guards `init-cron` (C), so the OVERALL exit code is ALWAYS 0 regardless of whether `init-firewall.sh` (A) succeeded. Verified by simulation: `bash -c 'false && echo B; echo C; false || true'` exits 0. This contradicts the CLI path: `entrypoint.sh` (lines 22-27) retries the firewall and `exit 1` on failure, treating a firewall failure as fatal. The asymmetry is security-relevant because `init-firewall.sh` has a real egress-OPEN window: between `iptables -P OUTPUT ACCEPT` (line 180) and `iptables -P OUTPUT DROP` (line 300) it runs commands under `set -e` that can abort nonzero — most concretely `ipset create allowed-domains hash:net` (line 202), which fails if the prior `ipset destroy` (line 170, best-effort `|| true`) could not remove the set (e.g. it is still referenced by a surviving rule or a concurrent run). If the script aborts there, OUTPUT policy is ACCEPT (egress fully OPEN). In the CLI path `entrypoint.sh` catches the nonzero exit and refuses to start; in the VS Code path the `; … || true` swallows it and `waitFor: postStartCommand` (line 57) sees success, so VS Code opens the workspace with the firewall absent and the user unaware.
- **Recommendation:** Make firewall failure fatal in the VS Code path too. Replace the `&& … ; … || true` chaining with a guarded form that only tolerates non-security steps, e.g.: `sudo FIREWALL_MODE=${FIREWALL_MODE:-strict} /usr/local/bin/init-firewall.sh && { claude update || true; /usr/local/bin/init-cron.sh || true; }`. This propagates a firewall nonzero exit as the overall postStartCommand exit (VS Code then surfaces the failure) while keeping claude-update and cron non-fatal.
