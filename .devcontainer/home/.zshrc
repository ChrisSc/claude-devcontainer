# ~/.zshrc — Claude sandbox shell. Baked into the image (not under any volume).
# Ordered for fast interactive startup.

# Heavy init only for interactive shells.
[[ $- != *i* ]] && return

# --- PATH (user-local tools, pnpm globals, npm globals) ---
export PNPM_HOME="$HOME/.local/share/pnpm"
export PATH="$HOME/.local/bin:$PNPM_HOME:/usr/local/share/npm-global/bin:$PATH"

# --- History: shared, persistent (on the command-history volume), deduped ---
export HISTFILE=/commandhistory/.zsh_history
export HISTSIZE=100000
export SAVEHIST=100000
setopt SHARE_HISTORY INC_APPEND_HISTORY EXTENDED_HISTORY
setopt HIST_IGNORE_ALL_DUPS HIST_IGNORE_SPACE HIST_REDUCE_BLANKS HIST_VERIFY

# --- Completion (daily-cached compdump for fast startup) ---
fpath+=(/usr/share/zsh-plugins/zsh-completions/src)    # must precede compinit
autoload -Uz compinit
if [[ -n ${ZDOTDIR:-$HOME}/.zcompdump(#qN.mh+24) ]]; then
    compinit
else
    compinit -C
fi
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'   # case-insensitive

# --- Plugins (direct source; no framework) ---
source /usr/share/zsh-plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
ZSH_AUTOSUGGEST_STRATEGY=(history completion)

# --- Tool integrations ---
eval "$(starship init zsh)"
eval "$(zoxide init zsh)"                       # z / zi
command -v direnv >/dev/null && eval "$(direnv hook zsh)"
# fzf keybindings: Ctrl-R history, Ctrl-T files, Alt-C cd.
# Debian's fzf ships example scripts (older fzf lacks `--zsh`); prefer those.
if [[ -f /usr/share/doc/fzf/examples/key-bindings.zsh ]]; then
    source /usr/share/doc/fzf/examples/key-bindings.zsh
    source /usr/share/doc/fzf/examples/completion.zsh 2>/dev/null || true
elif command -v fzf >/dev/null; then
    source <(fzf --zsh) 2>/dev/null || true
fi
export FZF_DEFAULT_COMMAND='fd --type f --hidden --follow --exclude .git'
export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
export FZF_ALT_C_COMMAND='fd --type d --hidden --follow --exclude .git'
export FZF_DEFAULT_OPTS='--height 40% --layout=reverse --border --preview-window=right:60%'

# --- Pager / man theming via bat ---
export PAGER='less -R'
export MANPAGER="sh -c 'col -bx | bat -l man -p'"
export BAT_THEME='ansi'

# --- Aliases ---
[ -f "$HOME/.config/zsh/aliases.zsh" ] && source "$HOME/.config/zsh/aliases.zsh"

# --- One-line orientation banner (firewall mode + claude version) ---
if [[ -o login ]]; then
    print -P "%F{cyan}claude-code%f sandbox · firewall=%F{yellow}${FIREWALL_MODE:-strict}%f · $(claude --version 2>/dev/null || echo claude) · see ~/.claude/ENVIRONMENT.md"
fi

# --- Syntax highlighting MUST be sourced last ---
source /usr/share/zsh-plugins/fast-syntax-highlighting/fast-syntax-highlighting.plugin.zsh
