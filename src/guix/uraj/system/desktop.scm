;;; desktop.scm -- shared base operating-system for personal machines.
;;;
;;; %desktop-base-os carries everything that does not depend on a
;;; specific machine's storage or role: the wenxin user account (empty
;;; first-login password + SSH key), PAM, OpenSSH, greetd with the niri
;;; session on VT1, the Guix Home environment, and the rosenthal
;;; desktop services.  Machine configs (env/guix/os/lappie.scm) and
;;; live images (env/guix/os/desktop-iso.scm) inherit from it and
;;; override only their differences.

(define-module (uraj system desktop)
  #:use-module (gnu)
  #:use-module (gnu bootloader)
  #:use-module (gnu bootloader grub)
  #:use-module (gnu home)
  #:use-module (gnu home services)
  #:use-module (gnu packages glib)        ;dbus (dbus-run-session)
  #:use-module (gnu packages linux)       ;btrfs-progs, linux-pam
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu services dbus)
  #:use-module (gnu services guix)
  #:use-module (gnu services security-token) ;pcscd
  #:use-module (gnu services ssh)
  #:use-module (gnu system nss)
  #:use-module (gnu system privilege)
  #:use-module (guix base32)
  #:use-module (guix download)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (nongnu packages linux)
  #:use-module (nongnu packages mozilla)
  #:use-module (nongnu system linux-initrd)
  #:use-module (rosenthal services base)
  #:use-module (rosenthal services desktop)
  #:use-module (srfi srfi-1)
  #:use-module (uraj hardware keyboard)
  #:use-module (uraj home niri)
  #:use-module (uraj packages window-managers)
  #:use-module (uraj utils file path)
  #:autoload (rosenthal packages wm) (noctalia)
  #:export (%desktop-base-os
            %desktop-openssh-configuration
            %desktop-tmp-file-system
            desktop-home-environment))

;;; The Home environment is embedded via guix-home-service-type: one
;;; "guix system reconfigure" builds and activates both system and home
;;; in a single generation, and "guix system roll-back" reverts both
;;; together -- no separate "guix home reconfigure" step.  The greetd
;;; session commands below start login shells that source the Guix Home
;;; environment.
;;;
;;; Unlike a "guix home reconfigure" config, this one is evaluated on
;;; the machine that *builds* the system -- the installers are built on
;;; an Ubuntu host -- while the target is Guix System.  The niri
;;; services' host detection (noctalia-for-host,
;;; host-uses-systemd-activation?) would therefore look at the wrong
;;; machine, so both choices are pinned to what a Guix System target
;;; needs: plain noctalia, whose locker uses Guix's own PAM, and portal
;;; activation by the session bus instead of the session Shepherd.

(define %desktop-trusted-channels-file
  (local-file
   (project-path "src/guix/uraj/system/trusted-channels.scm")
   "trusted-channels.scm"))

(define desktop-home-environment
  (home-environment
   (services
    (cons (simple-service
           'trusted-guix-channels
           home-files-service-type
           `((".config/guix/trusted-channels.scm"
              ,%desktop-trusted-channels-file)))
          (niri-desktop-home-services #:noctalia noctalia
                                      #:portals 'activation)))))

;;; SSH with key auth for wenxin; root login stays disabled
;;; (permit-root-login defaults to #f and root's shadow entry is
;;; locked).  Port 23333 everywhere: never the default 22.
(define %desktop-openssh-configuration
  (openssh-configuration
   (port-number 23333)
   (authorized-keys
    (list (list "wenxin"
                (plain-file
                 "wenxin-authorized-keys"
                 "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCaK0O50zlTIaIUeaAmfOXTYpansMf7wjQsZCprTIkp8OhgB7XvDwqzLP9xJ3yzKsej8Am4v02d1RHQgCFi2KDmSTAjBFScRAkb5gDXtchPxc0XH4EFNGT1MqmNubDFNsJdMIUyHiPw5iEjsH+pV9qEuWry+1YVNMefjbKz38XTO3r7Ti+Oxq62HErypslYbHUG2wP2c5mS6n+3Ty+Nq3UG8zqhGgd6iIqrNPYC0u6JLiYe/HD6yd3bGuFDAPwJvgKFeDp9R67ScK7BEY9Z5yv6BPKgwGeJ4UvUASpWNdIszIzR/e5qvYa3uBZPgR/6I4J7X8sk3UGtP6VRe2EgclYb simple\n"))))))

;;; Noctalia is NetworkManager's secret agent: it supplies the Wi-Fi
;;; passphrase, but authorization to create or change the connection is a
;;; separate Polkit decision.  A live user's empty Unix password cannot be
;;; submitted reliably by graphical authentication agents.  Let only the
;;; active local netdev user manage NetworkManager; other administrative
;;; actions retain the normal wheel authentication policy.
(define %desktop-network-manager-polkit-rules
  (file-union
   "desktop-network-manager-polkit-rules"
   `(("share/polkit-1/rules.d/20-network-manager-netdev.rules"
      ,(plain-file
        "20-network-manager-netdev.rules"
        "polkit.addRule(function(action, subject) {\n    if (action.id.indexOf(\"org.freedesktop.NetworkManager.\") === 0 &&\n        subject.local && subject.active && subject.isInGroup(\"netdev\")) {\n        return polkit.Result.YES;\n    }\n});\n")))))

;;; Fetch the Nonguix substitute signing key while building the system or
;;; image.  Pinning its hash makes authorization independent of mutable
;;; network content and requires no download during system activation.
(define %nonguix-signing-key
  (origin
    (method url-fetch)
    (uri "https://substitutes.nonguix.org/signing-key.pub")
    (sha256
     (base32 "0j66nq1bxvbxf5n8q2py14sjbkn57my0mjwq7k1qm9ddghca7177"))))

;;; Keep temporary files in memory (and swap under pressure).  The size is a
;;; ceiling rather than a reservation and can be changed at runtime with a
;;; tmpfs remount.
(define %desktop-tmp-file-system
  (file-system
    (mount-point "/tmp")
    (device "none")
    (type "tmpfs")
    (flags '(no-suid no-dev))
    (options "mode=1777,size=16G")
    (check? #f)
    (create-mount-point? #t)))

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

    ;; (kernel linux-lts)
    (kernel linux)
    (initrd microcode-initrd)
    ;; linux-firmware carries device firmware, while wireless-regdb supplies
    ;; regulatory.db for cfg80211's country-specific channel and transmit-power
    ;; rules.
    (firmware (list linux-firmware wireless-regdb))

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
     (cons* firefox           ;Mozilla Firefox from the Nonguix channel
            btrfs-progs       ;subvolume and snapshot management
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
     (cons* ;; Per-keyboard hwdb key remap from (uraj hardware keyboard):
            ;; physical Caps Lock → left Shift, left Shift → left Ctrl,
            ;; left Ctrl → Caps Lock.  Compiled into /etc/udev/hwdb.bin
            ;; at build time, so it applies in the console and in every
            ;; graphical session without per-user remapping.
            %keyboard-remap-hwdb-service

            ;; Let PipeWire and WirePlumber acquire bounded real-time
            ;; scheduling through the system bus instead of falling back to
            ;; normal priority with org.freedesktop.RealtimeKit1 unavailable.
            (service rtkit-service-type)

            ;; The Guix Home gpg-agent's scdaemon reaches OpenPGP smart
            ;; cards through pcscd (the stock gnupg has no internal CCID
            ;; driver).  Foreign hosts get their distro's pcscd instead.
            (service pcscd-service-type)

            ;; No password prompt is needed for NetworkManager in an active
            ;; local desktop session.  In particular this makes the live
            ;; image usable before its initially empty password is changed.
            (simple-service 'network-manager-netdev-polkit
                            polkit-service-type
                            (list %desktop-network-manager-polkit-rules))

            ;; The Home environment lives in the same generation as the
            ;; system; its activation runs as 'wenxin' on boot and on
            ;; reconfigure, populating ~/.guix-home.
            (service guix-home-service-type
                     (list (list "wenxin" desktop-home-environment)))

            ;; SSH config lives in %desktop-openssh-configuration above
            ;; (port 23333, wenxin key auth).
            (service openssh-service-type
                     %desktop-openssh-configuration)

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
              (guix-service-type config =>
                (guix-configuration
                 (inherit config)
                 ;; Prefer the SJTUG mirrors, retain the upstream build farms
                 ;; as fallbacks, and finally try the independent Nonguix
                 ;; cache for packages supplied by that channel.
                 (substitute-urls
                  '("https://mirror.sjtu.edu.cn/guix-bordeaux"
                    "https://mirror.sjtu.edu.cn/guix"
                    "https://bordeaux.guix.gnu.org"
                    "https://ci.guix.gnu.org"
                    "https://substitutes.nonguix.org"))
                 (authorized-keys
                  (cons %nonguix-signing-key
                        (guix-configuration-authorized-keys config)))))
              (delete mingetty-service-type))))))
