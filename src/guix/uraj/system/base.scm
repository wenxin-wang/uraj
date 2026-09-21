;;; base.scm -- shared base operating-system for personal machines.
;;;
;;; %desktop-base-os carries everything that does not depend on a
;;; specific machine's storage or role: the wenxin user account (empty
;;; first-login password + SSH key), PAM, OpenSSH, greetd with the niri
;;; session on VT1, the Guix Home environment, and the rosenthal
;;; desktop services.  Machine configs (env/guix/os/lappie.scm) and
;;; live images (env/guix/os/desktop-iso.scm) inherit from it and
;;; override only their differences.

(define-module (uraj system base)
  #:use-module (gnu)
  #:use-module (gnu bootloader)
  #:use-module (gnu bootloader grub)
  #:use-module (gnu home)
  #:use-module (gnu packages glib)        ;dbus (dbus-run-session)
  #:use-module (gnu packages linux)       ;btrfs-progs, linux-pam
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu services guix)
  #:use-module (gnu services ssh)
  #:use-module (gnu system nss)
  #:use-module (gnu system privilege)
  #:use-module (nongnu packages linux)
  #:use-module (nongnu system linux-initrd)
  #:use-module (rosenthal services base)
  #:use-module (rosenthal services desktop)
  #:use-module (srfi srfi-1)
  #:use-module (uraj home config niri)
  #:use-module (uraj home services noctalia)
  #:export (%desktop-base-os
            desktop-home-environment))

;;; The Home environment is embedded via guix-home-service-type: one
;;; "guix system reconfigure" builds and activates both system and home
;;; in a single generation, and "guix system roll-back" reverts both
;;; together -- no separate "guix home reconfigure" step.  The greetd
;;; session commands below start login shells that source the Guix Home
;;; environment.

(define desktop-home-environment
  (home-environment
   (services (niri-desktop-home-services))))

(define %desktop-base-os
  (operating-system
    ;; Required fields, given storage-free placeholders that inheriting
    ;; configs override: lappie points bootloader and file-systems at
    ;; its real disk, the live image keeps these defaults (its
    ;; bootloader is replaced by the image machinery anyway).
    (host-name "laptop")
    (bootloader
     (bootloader-configuration
      (bootloader grub-bootloader)))
    (file-systems %base-file-systems)

    (timezone "Asia/Shanghai")
    (locale "en_US.utf8")
    (name-service-switch %mdns-host-lookup-nss)

    (kernel linux)
    (initrd microcode-initrd)
    (firmware (list linux-firmware))

    (users
     (cons (user-account
            (name "wenxin")
            (comment "Wenxin Wang")
            (group "users")
            ;; Empty password: SSH key login works from the start, and
            ;; greetd accepts a bare RET for the first local login; set
            ;; a real password with `passwd` afterwards (PAM's nullok
            ;; below is what allows the empty password).
            (password (crypt "" "$6$abc"))
            (supplementary-groups '("wheel" "netdev" "audio" "video")))
           %base-user-accounts))

    (packages
     (cons* btrfs-progs       ;subvolume and snapshot management
            ;; dbus-run-session launches the niri session bus; dbus is
            ;; a service dependency but not part of %base-packages.
            dbus
            %base-packages))

    ;; noctalia's screen locker verifies passwords in-process against the
    ;; system PAM stack; pam_unix offloads to unix_chkpwd, which Guix
    ;; builds to live at /run/privileged/bin/unix_chkpwd.  It is not part
    ;; of %default-privileged-programs, so add the setuid copy.
    (privileged-programs
     (cons (privileged-program
            (program (file-append linux-pam "/sbin/unix_chkpwd"))
            (setuid? #t))
           %default-privileged-programs))

    ;; PAM accepts the empty first-login password (greetd login, sudo
    ;; and su before `passwd`); see the wenxin user-account above.
    (pam-services (base-pam-services #:allow-empty-passwords? #t))

    (services
     (cons* ;; The Home environment lives in the same generation as the
            ;; system; its activation runs as 'wenxin' on boot and on
            ;; reconfigure, populating ~/.guix-home.
            (service guix-home-service-type
                     (list (list "wenxin" desktop-home-environment)))

            ;; SSH with key auth for wenxin; root login stays disabled
            ;; (permit-root-login defaults to #f and root's shadow entry
            ;; is locked).
            (service openssh-service-type
                     (openssh-configuration
                      (authorized-keys
                       (list (list "wenxin"
                                   (plain-file
                                    "wenxin-authorized-keys"
                                    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCaK0O50zlTIaIUeaAmfOXTYpansMf7wjQsZCprTIkp8OhgB7XvDwqzLP9xJ3yzKsej8Am4v02d1RHQgCFi2KDmSTAjBFScRAkb5gDXtchPxc0XH4EFNGT1MqmNubDFNsJdMIUyHiPw5iEjsH+pV9qEuWry+1YVNMefjbKz38XTO3r7Ti+Oxq62HErypslYbHUG2wP2c5mS6n+3Ty+Nq3UG8zqhGgd6iIqrNPYC0u6JLiYe/HD6yd3bGuFDAPwJvgKFeDp9R67ScK7BEY9Z5yv6BPKgwGeJ4UvUASpWNdIszIzR/e5qvYa3uBZPgR/6I4J7X8sk3UGtP6VRe2EgclYb simple\n"))))))

            ;; VT1: login through tuigreet, then start the niri session;
            ;; VT2-6: plain shell logins (agreety), like the
            ;; %rosenthal-desktop-services/tuigreet layout.
            (service greetd-service-type
              (greetd-configuration
               (greeter-supplementary-groups '("video" "input"))
               (terminals
                (map (lambda (vt)
                       (greetd-terminal-configuration
                        (terminal-vt (number->string vt))
                        (terminal-switch (eqv? 1 vt))
                        ;; Both session commands below start login shells
                        ;; (bash -l via niri-greetd-user-session, $SHELL
                        ;; -l for the console VTs), so greetd's own
                        ;; profile sourcing would just double-source
                        ;; /etc/profile and ~/.profile.
                        (source-profile? #f)
                        (default-session-command
                         (if (eqv? 1 vt)
                             (greetd-tuigreet-session
                              (args (list "--cmd" (niri-greetd-user-session)
                                          "--time" "--user-menu" "--asterisks"
                                          "--remember" "--remember-session"
                                          "--power-shutdown" "loginctl poweroff"
                                          "--power-reboot" "loginctl reboot")))
                             (greetd-agreety-session
                              (command
                               (greetd-user-session
                                (command #~(getenv "SHELL")))))))))
                     (iota 6 1)))))

            ;; NetworkManager, wpa-supplicant, elogind, dbus, polkit, etc.
            ;; all come from %rosenthal-desktop-services/base (which builds
            ;; on %desktop-services).

            (modify-services %rosenthal-desktop-services/base
              (delete mingetty-service-type))))))
