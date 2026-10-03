# Run inside dbus-run-session so the bus stays available during cleanup.
# niri's spawn-at-startup starts the foreground Home Shepherd with the
# Wayland environment.  This wrapper owns its shutdown, not its startup.
set -u
: "${XDG_RUNTIME_DIR:?PAM must supply a runtime directory}"
: "${NIRI_SESSION_HERD:?Guix must supply the Home herd executable}"

niri_pid=
cleanup() {
    trap - EXIT HUP INT TERM
    if [ -n "$niri_pid" ]; then
        kill "$niri_pid" 2>/dev/null || :
        wait "$niri_pid" 2>/dev/null || :
    fi
    # An explicit user socket also prevents accidentally addressing PID 1.
    "$NIRI_SESSION_HERD" --socket "$XDG_RUNTIME_DIR/shepherd/socket" stop root || :
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

niri --session &
niri_pid=$!
status=0
wait "$niri_pid" || status=$?
niri_pid=
exit "$status"
