if [[ "$XDG_CURRENT_DESKTOP" =~ .*KDE ]]; then
    export XMODIFIERS='@im=fcitx'
fi
# It seems that modern GTK & QT does not need these.
# GTK_IM_MODULE=fcitx
# QT_IM_MODULE=fcitx

# If I set this, emacs would behave strangely, as if
# it treats all inputs as Chinese.
# LC_CTYPE=zh_CN.utf-8
