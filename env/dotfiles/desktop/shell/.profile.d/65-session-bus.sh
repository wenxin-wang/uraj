# SSH logins do not inherit the desktop bus used by gh's Secret Service
# keyring.  Reuse an existing bus; never start another password service.
if [ -n "${SSH_CONNECTION:-}" ] &&
   [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    _uraj_session_bus() (
        if [ -n "${XDG_RUNTIME_DIR:-}" ] &&
           [ -S "$XDG_RUNTIME_DIR/bus" ]; then
            printf 'unix:path=%s/bus\n' "$XDG_RUNTIME_DIR"
            exit
        fi

        # Guix System starts niri with dbus-run-session, whose socket is
        # not at $XDG_RUNTIME_DIR/bus.  Read only the bus address from a
        # compositor owned by this user, without importing its environment.
        command -v pgrep >/dev/null 2>&1 || exit 0
        for session_pid in $(pgrep -u "$(id -u)" -x niri 2>/dev/null); do
            session_bus=$(
                { tr '\000' '\n' < "/proc/$session_pid/environ"; } 2>/dev/null |
                    sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p'
            )
            case "$session_bus" in
                unix:path=*)
                    session_socket=${session_bus#unix:path=}
                    if [ -S "${session_socket%%,*}" ]; then
                        printf '%s\n' "$session_bus"
                        exit
                    fi
                    ;;
            esac
        done
    )
    if _uraj_bus=$(_uraj_session_bus) && [ -n "$_uraj_bus" ]; then
        export DBUS_SESSION_BUS_ADDRESS=$_uraj_bus
    fi
    unset _uraj_bus
    unset -f _uraj_session_bus
fi
