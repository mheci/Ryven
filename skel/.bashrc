# Ryven default bashrc
# If not running interactively, don't do anything
case $- in *i*) ;; *) return;; esac

# Starship prompt
eval "$(starship init bash)"

# Aliases
alias ls='eza --icons=auto'
alias ll='eza -lh --icons=auto'
alias la='eza -la --icons=auto'
alias lt='eza -T --icons=auto'
alias cat='bat --paging=never'
alias grep='grep --color=auto'
alias ..='cd ..'
alias ...='cd ../..'

# Path
export PATH="$HOME/.local/bin:$PATH"
export EDITOR='nvim'
export VISUAL='nvim'
