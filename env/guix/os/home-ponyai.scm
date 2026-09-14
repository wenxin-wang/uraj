;; This "home-environment" file can be passed to 'guix home reconfigure'
;; to reproduce the content of your profile.  This is "symbolic": it only
;; specifies package names.  To reproduce the exact same profile, you also
;; need to capture the channels being used, as returned by "guix describe".
;; See the "Replicating Guix" section in the manual.

(use-modules (gnu home)
             (gnu packages)
             (gnu services)
             (guix gexp)
             (gnu home services shells)
             (uraj common basic-packages)
             (uraj common basic-services)
             (uraj utils file path))

(home-environment
  ;; Below is the list of packages that will show up in your
  ;; Home profile, under ~/.guix-home/profile.
 (packages (append
            (list
             glibc-common-locales)
            (specifications->packages
            (list "flameshot"))))

 ;; Below is the list of Home services.  To search for available
 ;; services, run 'guix home search KEYWORD' in a terminal.
 (services
  (append (my-dotfiles-services (list (project-path "env/dotfiles/common")))
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
