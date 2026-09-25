# Use gpg-agent for SSH authentication.  OpenPGP-card authentication keys are
# available here when a YubiKey or CanoKey is inserted.
export SSH_AUTH_SOCK="$(gpgconf --list-dirs agent-ssh-socket)"

# OpenSSH only invokes askpass when no TTY is available and DISPLAY is set.
# Resolve the Guix-profile program dynamically instead of assuming /usr/bin.
if _ssh_askpass=$(command -v ksshaskpass 2>/dev/null); then
    export SSH_ASKPASS="$_ssh_askpass"
fi
unset _ssh_askpass
