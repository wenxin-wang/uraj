# Use gpg-agent for SSH authentication when the session does not already have
# an agent.  In particular, preserve the socket installed by `ssh -A` so agent
# forwarding keeps working in remote login shells.
if [ -z "${SSH_AUTH_SOCK:-}" ]; then
    export SSH_AUTH_SOCK="$(gpgconf --list-dirs agent-ssh-socket)"
fi

# The desktop supplies ksshaskpass with QtKeychain: in niri its libsecret
# backend uses the session's GNOME Keyring, including a foreign host's daemon.
# OpenSSH normally uses the TTY when available; do not force graphical prompts
# in remote shells.  Headless broker launches can use the inherited askpass.
# Resolve the Guix-profile program dynamically instead of assuming /usr/bin.
if _ssh_askpass=$(command -v ksshaskpass 2>/dev/null); then
    export SSH_ASKPASS="$_ssh_askpass"
fi
unset _ssh_askpass
