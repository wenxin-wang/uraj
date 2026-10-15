# Use sh for the wrapper itself, so Bash's remote startup files cannot run
# before --norc takes effect. Keep an explicitly selected interpreter.
export DIRENV_BASH="${DIRENV_BASH:-$HOME/.local/bin/uraj-direnv-bash}"
