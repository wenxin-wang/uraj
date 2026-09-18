;; This "home-environment" file can be passed to 'guix home reconfigure'
;; to reproduce the content of your profile.  This is "symbolic": it only
;; specifies package names.  To reproduce the exact same profile, you also
;; need to capture the channels being used, as returned by "guix describe".
;; See the "Replicating Guix" section in the manual.

(use-modules (gnu home)
             (gnu home services)
             (gnu packages)
             (gnu packages fcitx5)
             (gnu services)
             (rosenthal services desktop)
             (uraj common basic-packages)
             (uraj common basic-services)
             (uraj home services noctalia)
             (uraj utils file path))

(home-environment
 ;; Below is the list of packages that will show up in your
 ;; Home profile, under ~/.guix-home/profile.
 (packages (append
            (list
             glibc-common-locales
             ;; ~/.config/gtk-3.0/settings.ini 全局设置 gtk-im-module=fcitx，
             ;; guix 侧也要有这个 immodule 供 guix GTK3 应用加载
             (list fcitx5-gtk "gtk3"))
            (specifications->packages
             (list "flameshot"
                   "niri"
                   "wezterm"          ;terminal emulator
                   "wl-clipboard"
                   "xdg-desktop-portal-gnome" ;screencast/screenshots
                   "xdg-desktop-portal-gtk"
                   "xorg-server-xwayland" ;X11 apps (fcitx5 XIM)
                   "xwayland-satellite")))) ;niri spawns it for X11 support

 ;; Below is the list of Home services.  To search for available
 ;; services, run 'guix home search KEYWORD' in a terminal.
 (services
  (append
   (my-dotfiles-services (list (project-path "env/dotfiles/common")))
   ;; The niri + noctalia session; the host display manager (GDM) runs
   ;; "niri --session", which spawns the session Shepherd these services
   ;; extend.  See (uraj home services noctalia) for the host-side
   ;; contract (the niri-session wrapper) and the screen-locker PAM
   ;; patch details.
   (home-niri-noctalia-services)
   (list
    (service home-fcitx5-service-type
             (home-fcitx5-configuration
              ;; 纯 Wayland 会话（niri）：不导出 GTK_IM_MODULE，避免 fcitx5
              ;; 每次登录弹 wayland-diagnose-other 通知
              (wayland-frontend? #t)
              (themes (list fcitx5-material-color-theme))
              (input-method-editors (list fcitx5-rime)))))
   %base-home-services)))
;; (services
;;  (append (list (service home-bash-service-type
;;                         (home-bash-configuration
;;                          (aliases '(("alert" . "notify-send --urgency=low -i \"$([ $? = 0 ] && echo terminal || echo error)\" \"$(history|tail -n1|sed -e '\\''s/^\\s*[0-9]\\+\\s*//;s/[;&|]\\s*alert$//'\\'')\"")
;;                                     ("b" . "cd -")
;;                                     ("df" . "df -h")
;;                                     ("e" . "emacsclient -t -a emacs")
;;                                     ("g++" . "g++ -W -Wall")
;;                                     ("gcc" . "gcc -W -Wall")
;;                                     ("l" . "ls -CFh")
;;                                     ("la" . "ls -Ah")
;;                                     ("ll" . "ls -alh")
;;                                     ("lld" . "ls -d .*")
;;                                     ("llld" . "ll -d .*")
;;                                     ("looplay" . "mplayer -loop 0")
;;                                     ("mnt" . "udevil mount $@")
;;                                     ("newsmth" . "luit -encoding gbk ssh wwxwwx@newsmth.net")
;;                                     ("newsmth-expect" . "expect -c \"set timeout 60; spawn luit -encoding gbk ssh newsmth.net; interact timeout 30  {send \\\"\\000\\\"}; \"")
;;                                     ("p8" . "/home/wenxin/.local/bin/pony-repo")
;;                                     ("panlatex" . "pandoc --template=/home/wenxin/snippets/tex/pandoc.tex --latex-engine=xelatex -t latex")
;;                                     ("u" . "cd ..")
;;                                     ("umnt" . "udevil umount $@")))
;;                          (bashrc (list (local-file "./.bashrc" "bashrc")))
;;                          (bash-profile (list (local-file "./.bash_profile"
;;                                                          "bash_profile")))
;;                          (bash-logout (list (local-file "./.bash_logout"
;;                                                         "bash_logout"))))))
;;          %base-home-services)))
