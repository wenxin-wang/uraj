;; This "home-environment" file can be passed to 'guix home reconfigure'
;; to reproduce the content of your profile.  This is "symbolic": it only
;; specifies package names.  To reproduce the exact same profile, you also
;; need to capture the channels being used, as returned by "guix describe".
;; See the "Replicating Guix" section in the manual.

(use-modules (gnu home)
             (gnu home services)
             (gnu home services shepherd)
             (gnu packages)
             (gnu packages fcitx5)
             (gnu services)
             (gnu services shepherd)
             (guix gexp)
             (ice-9 rdelim)
             (rosenthal services desktop)
             (srfi srfi-13)
             (uraj common basic-packages)
             (uraj common basic-services)
             (uraj home services noctalia)
             (uraj utils file path))

;; Guix's libpam cannot parse Ubuntu's "@include" PAM files, and Guix's
;; loader cannot reach multiarch libraries, so noctalia's screen locker
;; preloads Ubuntu's libpam and its modules' dependency closure (the
;; 'ldd' closure of the modules reachable from /etc/pam.d/login).  No
;; libc is preloaded; the host's /sbin/unix_chkpwd still verifies the
;; password against /etc/shadow.  The closure differs per release, so
;; pick it by the host's /etc/os-release.

(define (ubuntu-pam-preload libs)
  (string-join (map (lambda (lib)
                      (string-append "/usr/lib/x86_64-linux-gnu/" lib))
                    libs)
               ":"))

(define %ubuntu-pam-preload-22.04
  (ubuntu-pam-preload
   '("libpam.so.0"
     "libaudit.so.1"
     "libcap-ng.so.0"
     "libcap.so.2"
     "libcom_err.so.2"
     "libcrack.so.2"
     "libcrypt.so.1"
     "libecryptfs.so.1"
     "libgssapi_krb5.so.2"
     "libk5crypto.so.3"
     "libkeyutils.so.1"
     "libkrb5.so.3"
     "libkrb5support.so.0"
     "libnsl.so.2"
     "libnspr4.so"
     "libnss3.so"
     "libnssutil3.so"
     "libpam_misc.so.0"
     "libpcre2-8.so.0"
     "libplc4.so"
     "libplds4.so"
     "libpwquality.so.1"
     "libselinux.so.1"
     "libtirpc.so.3")))

(define %ubuntu-pam-preload-24.04
  ;; 24.04's login chain no longer pulls in krb5/nsl/tirpc.
  (ubuntu-pam-preload
   '("libpam.so.0"
     "libaudit.so.1"
     "libcap-ng.so.0"
     "libcap.so.2"
     "libcrack.so.2"
     "libcrypt.so.1"
     "libecryptfs.so.1"
     "libkeyutils.so.1"
     "libnspr4.so"
     "libnss3.so"
     "libnssutil3.so"
     "libpam_misc.so.0"
     "libpcre2-8.so.0"
     "libplc4.so"
     "libplds4.so"
     "libpwquality.so.1"
     "libselinux.so.1")))

(define (%os-release-field name)
  "Return the value of field NAME from /etc/os-release, or #f."
  (and (file-exists? "/etc/os-release")
       (call-with-input-file "/etc/os-release"
         (lambda (port)
           (let loop ((line (read-line port)))
             (cond
              ((eof-object? line) #f)
              ((string-prefix? (string-append name "=") line)
               (let ((value (substring line (+ (string-length name) 1))))
                 ;; Strip quotes, e.g. VERSION_ID="24.04".
                 (if (and (> (string-length value) 1)
                          (char=? #\" (string-ref value 0))
                          (char=? #\" (string-ref value (1- (string-length value)))))
                     (substring value 1 (1- (string-length value)))
                     value)))
              (else (loop (read-line port)))))))))

(define (ubuntu-pam-preload-for-version version)
  (cond ((string=? "22.04" version) %ubuntu-pam-preload-22.04)
        ((string=? "24.04" version) %ubuntu-pam-preload-24.04)
        (else #f)))

(define (host-ubuntu-pam-preload)
  "Return the LD_PRELOAD string for the host's Ubuntu PAM stack, or #f
if the host is not Ubuntu 22.04/24.04."
  (and (string=? "ubuntu" (or (%os-release-field "ID") ""))
       (ubuntu-pam-preload-for-version (%os-release-field "VERSION_ID"))))

(home-environment
 ;; Below is the list of packages that will show up in your
 ;; Home profile, under ~/.guix-home/profile.
 (packages (append
            (list
             glibc-common-locales)
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
   (list
    ;; The session is managed by the host display manager (GDM on Ubuntu).
    ;; GDM runs /usr/local/bin/niri-session (host-side wrapper, see below),
    ;; which sources the Guix Home environment and execs:
    ;;   niri --session
    ;; niri then spawns the user Shepherd (spawn-at-startup "shepherd"),
    ;; which starts noctalia and fcitx5 inside the graphical session.
    ;;
    ;; Host-side wrapper (/usr/local/bin/niri-session):
    ;;   #!/bin/sh
    ;;   [ -f "$HOME/.guix-home/setup-environment" ] && \
    ;;       . "$HOME/.guix-home/setup-environment"
    ;;   if [ -n "$DBUS_SESSION_BUS_ADDRESS" ]; then
    ;;       niri --session
    ;;   else
    ;;       dbus-run-session -- niri --session
    ;;   fi
    ;;   # niri exited: logind leaves processes behind (Ubuntu default
    ;;   # KillUserProcesses=no), so tear the session Shepherd down
    ;;   # explicitly. This stops noctalia/fcitx5 and frees the Shepherd
    ;;   # socket for the next login. Note: niri must NOT be exec'd here,
    ;;   # otherwise this cleanup never runs.
    ;;   herd stop root 2>/dev/null || true
    ;;
    ;; The session bus is provided by the host system (systemd/logind), hence
    ;; the stub 'dbus' Shepherd service instead of home-dbus-service-type.
    ;; Start Shepherd from niri (spawn-at-startup "shepherd") so that it
    ;; inherits the graphical session environment.
    (service home-shepherd-service-type
             (home-shepherd-configuration
              (auto-start? #f)
              (daemonize? #f)))

    ;; The session bus is provided by the host system.
    (simple-service 'dbus home-shepherd-service-type
                    (list (shepherd-service
                           (provision '(dbus))
                           (start #~(const #t))
                           (stop #~(const #f)))))

    (service home-noctalia-service-type
             (home-noctalia-configuration
              (environment-variables
               (let ((preload (host-ubuntu-pam-preload)))
                 (if (and preload
                          (file-exists? "/usr/lib/x86_64-linux-gnu/libpam.so.0"))
                     (list (string-append "LD_PRELOAD=" preload))
                     '())))))

    (service home-fcitx5-service-type
             (home-fcitx5-configuration
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
