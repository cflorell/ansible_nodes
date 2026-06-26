export EDITOR=nvim

if ! command -v "$starship" > /dev/null;
then
  eval "$(starship init bash)"
fi

for file in $HOME/.config/bash/*.sh; do
  source "$file"
done

# Fuzzy completion
eval <(fzf --bash)

# history
HISTFILE=~/.bash_history
HISTSIZE=10000
SAVEHIST=10000
setopt appendhistory

export PATH="$HOME/bin:$PATH"
