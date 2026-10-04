# Run inside dbus-run-session so the bus stays available during cleanup.
# niri's spawn-at-startup starts the foreground Home Shepherd with the
# Wayland environment.  This wrapper owns its shutdown, not its startup.
set -u
: "${XDG_RUNTIME_DIR:?PAM must supply a runtime directory}"
: "${NIRI_SESSION_HERD:?Guix must supply the Home herd executable}"
: "${NIRI_SESSION_LOG_FILE:?Guix Home must supply the niri log path}"

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

# Guix Home supplies the same path to its log-rotation service.  It treats this
# as an external log (copy + truncate); append mode keeps writes correct
# after truncation, without restarting niri or handing it to Shepherd.
niri_log_dir="${NIRI_SESSION_LOG_FILE%/*}"
if (umask 077; mkdir -p "$niri_log_dir" && : >> "$NIRI_SESSION_LOG_FILE"); then
    niri --session >> "$NIRI_SESSION_LOG_FILE" 2>&1 &
else
    echo "Cannot open niri log; keeping output on the session terminal" >&2
    niri --session &
fi
niri_pid=$!
status=0
wait "$niri_pid" || status=$?
niri_pid=
exit "$status"
