# Aliases — modern tool mappings. Interactive shells only (scripts / non-interactive
# `sh` get the real coreutils). Safe tier: only low-risk, high-payoff overrides.
# Escape hatches use `command <tool>`.

# ls -> eza
alias ls='eza --group-directories-first'
alias ll='eza -lah --git --group-directories-first'
alias la='eza -a'
alias lt='eza --tree --level=2'
alias tree='eza --tree'

# cat -> bat (paging off so pipes behave like cat)
alias cat='bat --paging=never'
alias catp='command cat'          # raw cat

# cd -> zoxide (plain `cd <path>` still works via zoxide)
alias cd='z'

# system monitor / git ui
alias top='btm'
alias lg='lazygit'

# git
alias gs='git status'
alias gd='git diff'
alias gl='git log --oneline --graph --decorate -20'

# new verbs for tools we deliberately DON'T shadow (grep/find/ps/du keep coreutils)
alias rgi='rg -i'
alias fda='fd --hidden --no-ignore'
alias d='dust'
alias p='procs'

# python via uv (never bare python)
alias py='uv run python'
