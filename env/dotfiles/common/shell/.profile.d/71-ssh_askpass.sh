export SSH_AUTH_SOCK=$(gpgconf --list-dirs agent-ssh-socket)

if [[ "$XDG_CURRENT_DESKTOP" =~ .*KDE ]]; then
    export SSH_ASKPASS=/usr/bin/ksshaskpass
    export SSH_ASKPASS_REQUIRE=prefer
fi
