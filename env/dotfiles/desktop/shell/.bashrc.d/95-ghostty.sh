# ssh only forwards TERM, so the COLORTERM/TERM_PROGRAM that ghostty sets
# locally are lost on the remote host. Mirror them here; without COLORTERM,
# env-based color detection (chalk/Node) reads xterm-ghostty as 16 colors.
case "${TERM-}" in
    xterm-ghostty)
        export COLORTERM="${COLORTERM:-truecolor}"
        export TERM_PROGRAM="${TERM_PROGRAM:-ghostty}"
        ;;
esac
