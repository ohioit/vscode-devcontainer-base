if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

export ZSH="${HOME}/.oh-my-zsh"
export TERM="xterm-256color"

ZSH_THEME="powerlevel10k/powerlevel10k"

HYPHEN_INSENSITIVE="true"
COMPLETION_WAITING_DOTS="true"

DISABLE_UPDATE_PROMPT="true"

plugins=(k genpass gitfast kubetail colorize docker helm ubuntu zsh-autosuggestions zsh-interactive-cd zsh-syntax-highlighting)

source $ZSH/oh-my-zsh.sh

typeset -gA ZSH_HIGHLIGHT_STYLES

ZSH_HIGHLIGHT_HIGHLIGHTERS=(main brackets pattern cursor)
ZSH_HIGHLIGHT_STYLES[cursor]='bold'

ZSH_HIGHLIGHT_STYLES[alias]='fg=green,bold'
ZSH_HIGHLIGHT_STYLES[suffix-alias]='fg=green,bold'
ZSH_HIGHLIGHT_STYLES[builtin]='fg=green,bold'
ZSH_HIGHLIGHT_STYLES[function]='fg=green,bold'
ZSH_HIGHLIGHT_STYLES[command]='fg=green,bold'
ZSH_HIGHLIGHT_STYLES[precommand]='fg=green,bold'
ZSH_HIGHLIGHT_STYLES[hashed-command]='fg=green,bold'

rule () {
	print -Pn '%F{blue}'
	local columns=$(tput cols)
	for ((i=1; i<=columns; i++)); do
	   printf "\u2588"
	done
	print -P '%f'
}

function _my_clear() {
	echo
	rule
	zle clear-screen
}
zle -N _my_clear
bindkey '^l' _my_clear

export EDITOR='vim'

export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$HOME/.local/bin:$HOME/.bin:/usr/local/bin:${PATH}"

if [[ -e "$HOME/.zsh/kubernetes.sh" ]]; then
	source "$HOME/.zsh/kubernetes.sh"
elif [[ -n "$(which kubectl 2>/dev/null)" ]]; then
	echo "Generating kubectl completions..."
	mkdir "$HOME/.zsh" || true
	kubectl completion zsh > "$HOME/.zsh/kubernetes.sh"
	source "$HOME/.zsh/kubernetes.sh"
fi

alias pretty="ccat"
alias git-oops="git add . && git commit --amend --no-edit -a && git push --force"

source "${HOME}/.zsh-aliases.zsh"

echo "Pst! Remember about these Krew plugins:"
kubectl krew list
echo "...and tools: pretty, ccat, cless, kdiag, k, kubetail"

# To customize prompt, run `p10k configure` or edit ~/.p10k.zsh.
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh
