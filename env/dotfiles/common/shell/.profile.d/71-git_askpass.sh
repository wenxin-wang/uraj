if [[ "$XDG_CURRENT_DESKTOP" =~ .*KDE ]]; then
    export GIT_ASKPASS=/usr/bin/ksshaskpass
fi
