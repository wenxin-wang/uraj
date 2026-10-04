;;; desktop.scm -- graphical services layered on (uraj system base).
;;;
;;; Inherits the account, kernel, SSH policy, and Guix settings from base;
;;; adds greetd/niri, Guix Home, and Rosenthal desktop services.  Machine
;;; configurations supply storage and hardware, and to-iso derives live media.

(define-module (uraj system desktop)
  #:use-module (gnu)
  #:use-module (gnu home)
  #:use-module (gnu home services)
  #:use-module (gnu packages glib)        ;dbus (dbus-run-session)
  #:use-module (gnu packages gnome)       ;network-manager-applet
  #:use-module (gnu packages linux)       ;linux-pam
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu services containers)  ;rootless podman
  #:use-module (gnu services dbus)
  #:use-module (gnu services desktop)
  #:use-module (gnu services guix)
  #:use-module (gnu services networking)
  #:use-module (gnu services security-token) ;pcscd
  #:use-module (gnu system accounts)      ;subid-range
  #:use-module (gnu system nss)
  #:use-module (gnu system privilege)
  #:use-module (guix gexp)
  #:use-module (srfi srfi-1)
  #:use-module (nongnu packages linux)
  #:use-module (nongnu packages mozilla)
  #:use-module (rosenthal services base)
  #:use-module (rosenthal services desktop)
  #:use-module (uraj common context)
  #:use-module (uraj hardware keyboard)
  #:use-module (uraj home niri)
  #:use-module (uraj packages window-managers)
  #:use-module (uraj packages elogind)
  #:use-module (uraj packages wireless)
  #:use-module (uraj services desktop)
  #:use-module (uraj system base)
  #:use-module (uraj system home)
  #:use-module (uraj utils file path)
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
;;; Construct the embedded Home under the target account's context.
;;; Foreign-host detection must not inspect the system's build machine.

(define %desktop-trusted-channels-file
  (local-file
   (project-path "env/guix/trusted-channels.scm")
   "trusted-channels.scm"))

(define desktop-home-environment
  (parameterize ((%main-user %base-user)
                 (%for-foreign-home #f))
    (home-environment
     (packages (list network-manager-applet))
     (services
      (cons (simple-service
             'trusted-guix-channels
             home-files-service-type
             `((".config/guix/trusted-channels.scm"
                ,%desktop-trusted-channels-file)))
            (niri-desktop-home-services))))))

(define %desktop-openssh-configuration %base-openssh-configuration)
(define %desktop-tmp-file-system %tmp-file-system)

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

(define %desktop-base-os
  (operating-system
    (inherit %base-os)
    (host-name "laptop")
    (name-service-switch %mdns-host-lookup-nss)

    (firmware (list linux-firmware wireless-regdb-signed))

    (users
     (cons (user-account
            (inherit %base-user)
            ;; "cgroup" is rootless-podman-service-type's group owning
            ;; the delegated /sys/fs/cgroup controllers.
            (supplementary-groups
             '("wheel" "netdev" "audio" "video" "cgroup")))
           (remove (lambda (user)
                     (string=? (user-account-name user) "wenxin"))
                   (operating-system-users %base-os))))

    (packages
     (cons* firefox           ;Mozilla Firefox from the Nonguix channel
            ;; dbus-run-session launches the niri session bus; dbus is
            ;; a service dependency but not part of %base-packages.
            dbus
            (operating-system-packages %base-os)))

    ;; noctalia's screen locker verifies passwords in-process against the
    ;; system PAM stack; pam_unix offloads to unix_chkpwd, which Guix
    ;; builds to live at /run/privileged/bin/unix_chkpwd.  It is not part
    ;; of %default-privileged-programs, so add the setuid copy.
    (privileged-programs
     (cons (privileged-program
            (program (file-append linux-pam "/sbin/unix_chkpwd"))
            (setuid? #t))
           %default-privileged-programs))

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

            bluetooth-gatt-release-service

            ;; The Guix Home gpg-agent's scdaemon reaches OpenPGP smart
            ;; cards through pcscd (the stock gnupg has no internal CCID
            ;; driver).  Foreign hosts get their distro's pcscd instead.
            (service pcscd-service-type)

            ;; Rootless Podman: subuid/subgid ranges, cgroup v2 delegation,
            ;; a shared root mount and /etc/containers defaults.  The podman
            ;; CLI itself comes from the basic-dev home profile.  No
            ;; iptables-service-type: netavark >= 2.0 only speaks nftables,
            ;; and rootless rules live in podman's own network namespace.
            (service rootless-podman-service-type
                     (rootless-podman-configuration
                      (podman #f)
                      (subuids (list (subid-range (name "wenxin"))))
                      (subgids (list (subid-range (name "wenxin"))))))

            ;; No password prompt is needed for NetworkManager in an active
            ;; local desktop session.  In particular this makes the live
            ;; image usable before its initially empty password is changed.
            (simple-service 'network-manager-netdev-polkit
                            polkit-service-type
                            (list %desktop-network-manager-polkit-rules))

            ;; The Home environment lives in the same generation as the
            ;; system; its activation runs as 'wenxin' on boot and on
            ;; reconfigure, populating ~/.guix-home.
            (service guix-home-with-environment-service-type
                     (list (list "wenxin" desktop-home-environment)))

            ;; VT1: login through tuigreet, then start the niri session;
            ;; VT2-6: plain shell logins (agreety), like the
            ;; %rosenthal-desktop-services/tuigreet layout.
            (service greetd-with-elogind-service-type
              (base-greetd-configuration
               (lambda (vt)
                 (if (= vt 1)
                     (greetd-tuigreet-session
                      (args (list "--cmd" (niri-greetd-user-session)
                                  "--time" "--user-menu" "--asterisks"
                                  "--remember" "--remember-session"
                                  "--power-shutdown" "loginctl poweroff"
                                  "--power-reboot" "loginctl reboot")))
                     %greetd-console-session))
               (greeter-supplementary-groups '("video" "input"))))

            ;; NetworkManager, wpa-supplicant, elogind, dbus, polkit, etc.
            ;; all come from %rosenthal-desktop-services/base (which builds
            ;; on %desktop-services).

            (base-services
             (modify-services %rosenthal-desktop-services/base
               (elogind-service-type config =>
                 (elogind-configuration
                  (inherit config)
                  (elogind elogind-with-shepherd-kexec)))
               ;; Cellular support is opt-in; unused ModemManager delay
               ;; inhibitors can hold up suspend on machines without modems.
               (delete modem-manager-service-type)
               (delete mingetty-service-type)))))))
