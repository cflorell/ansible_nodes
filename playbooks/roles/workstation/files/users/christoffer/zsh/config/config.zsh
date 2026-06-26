# Enable tab completion for tmux
source  $HOME/.tmux/plugins/completion/tmux

# Add /home/$USER/.tmux/tmuxifier to $PATH
case :$PATH: in
	*:/home/$USER/.tmux/tmuxifier/bin:*) ;;
	*) PATH=/home/$USER/.tmux/tmuxifier/bin:$PATH ;;
esac