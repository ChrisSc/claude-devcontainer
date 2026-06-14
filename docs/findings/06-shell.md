# shell — audit findings

Overall the shell configuration is in reasonable health, with a single medium-severity performance issue. The `.zshrc` attempts a daily-cached `compinit` fast path for faster interactive startup, but the guard test is implemented with a construct that never performs the intended glob, rendering the fast path unreachable dead code. No correctness or security defects were found — the impact is limited to slower-than-intended shell startup. One finding is documented below.

## compinit cache fast-path is dead code: `[[ -n PATH(#qN.mh+24) ]]` is always true

- **Severity / kind:** medium / perf
- **Location:** [`.devcontainer/home/.zshrc:21`](.devcontainer/home/.zshrc#L21)
- **Evidence:**

  ```zsh
  if [[ -n ${ZDOTDIR:-$HOME}/.zcompdump(#qN.mh+24) ]]; then
      compinit
  else
      compinit -C
  fi
  ```

- **Why it matters:** Inside zsh `[[ ... ]]` no filename generation (globbing) is performed, so the glob qualifier `(#qN.mh+24)` is never evaluated against the filesystem — the operand is just the literal string `/home/claude/.zcompdump(#qN.mh+24)`, which is always non-empty. Therefore `[[ -n ... ]]` is ALWAYS true and the branch ALWAYS runs plain `compinit`; the `compinit -C` fast path is unreachable dead code. Verified by direct reproduction on zsh 5.9: with extendedglob OFF (as in this `.zshrc`), ON, missing dump, and fresh dump, the result is TRUE in every case. The comment on line 18 ('daily-cached compdump for fast startup') describes behavior that never occurs — every interactive shell pays the full compaudit security scan that `-C` was meant to skip. The author confused `[[ -n STRING ]]` with the correct array-glob idiom `dump=(...(Nmh+24)); (( ${#dump} ))`.
- **Recommendation:** Replace the broken test with the standard zsh idiom that actually performs the glob in command position, e.g.:

  ```zsh
  autoload -Uz compinit
  setopt local_options extended_glob
  if [[ -n ${ZDOTDIR:-$HOME}/.zcompdump(#qNmh+24) ]]; then compinit; else compinit -C; fi
  ```

  written as `local dump=(${ZDOTDIR:-$HOME}/.zcompdump(Nmh+24)); if (( ${#dump} )) || [[ ! -e ${ZDOTDIR:-$HOME}/.zcompdump ]]; then compinit; else compinit -C; fi` so a stale-OR-missing dump triggers a full `compinit` and a fresh dump uses `-C`. Note `(#q...)` requires EXTENDED_GLOB, which this file never sets — add `setopt extended_glob` (scoped) or use the array form which evaluates the qualifier regardless.
