(define-module (uraj packages window-managers)
  #:use-module (gnu home services)
  #:use-module (gnu home services shepherd)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages elf)
  #:use-module (gnu services)
  #:use-module ((gnu services base) #:select (greetd-user-session))
  #:use-module (gnu services shepherd)
  #:use-module (guix build-system trivial)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (ice-9 rdelim)
  #:use-module (srfi srfi-13)
  #:autoload (gnu packages freedesktop) (xdg-desktop-portal
                                        xdg-desktop-portal-gtk)
  #:autoload (gnu packages glib) (dbus)
  #:autoload (gnu packages gnome) (xdg-desktop-portal-gnome)
  #:autoload (gnu packages xorg) (xwayland-satellite)
  #:autoload (rosenthal packages wm) (noctalia)
  #:export (noctalia-for-host
            host-uses-systemd-activation?
            home-niri-noctalia-services
            home-niri-portal-services
            home-niri-session-services
            niri-greetd-user-session))

(define (noctalia-with-host-pam noctalia pam-libs)
  "Return NOCTALIA with PAM-LIBS, a list of absolute file names of the
host's PAM stack and its dependency closure, added as DT_NEEDED entries.

Noctalia's in-process screen locker parses the host's /etc/pam.d files
and loads the host's PAM modules; those modules live in the multiarch
directory, which the Guix loader cannot reach.  patchelf --add-needed
prepends the closure to the binary's DT_NEEDED list, so the host
libraries load first and the original @code{libpam.so.0} entry is
satisfied by the host's copy -- the same load order an LD_PRELOAD of the
closure produces, but without any environment variable that could leak
into programs noctalia spawns."
  (package
    (inherit noctalia)
    (name "noctalia-with-host-pam")
    (source #f)
    (build-system trivial-build-system)
    (arguments
     (list
      #:modules '((guix build utils))
      #:builder
      #~(begin
          (use-modules (guix build utils))
          (copy-recursively #$noctalia #$output)
          (let ((bin (string-append #$output "/bin/noctalia")))
            ;; The copy keeps the store's read-only permissions.
            (chmod bin #o755)
            (for-each (lambda (lib)
                        (invoke #$(file-append patchelf "/bin/patchelf")
                                "--add-needed" lib bin))
                      '#$pam-libs)))))
    (inputs (list noctalia))
    (native-inputs (list patchelf))))

;;; Noctalia's screen locker verifies passwords with the host's PAM
;;; stack, in-process.  Guix's libpam silently skips Ubuntu's "@include"
;;; directives (so pam_authenticate can never succeed) and its loader
;;; cannot reach the multiarch libraries the host's PAM modules need, so
;;; on Ubuntu hosts noctalia runs as the patched variant above whose
;;; DT_NEEDED list prepends the host PAM closure.  The closure differs
;;; per release, so pick it by the host's /etc/os-release.
;;;
;;; "The host" is the machine the home environment runs on, and the
;;; detection only holds for configs that are evaluated on that same
;;; machine -- "guix home reconfigure" ones like
;;; env/guix/os/home-ponyai.scm, which work unchanged on any Ubuntu
;;; release and fall back to plain noctalia everywhere else
;;; (noctalia-for-host is also the services' default).  A Guix System
;;; config must pin the package instead: its home environment is built
;;; *on* whatever machine runs the build -- a developer's Ubuntu box for
;;; the installers -- while the target is Guix System, where the patch's
;;; absolute /usr/lib/x86_64-linux-gnu paths do not exist and the loader
;;; refuses to run the binary at all.  Guix System's own PAM is what
;;; plain noctalia uses there (see the unix_chkpwd privileged program in
;;; (uraj system desktop)); (uraj system desktop) passes plain noctalia
;;; explicitly for this reason.

(define (ubuntu-pam-libs libs)
  (map (lambda (lib)
         (string-append "/usr/lib/x86_64-linux-gnu/" lib))
       libs))

(define %ubuntu-pam-libs-22.04
  (ubuntu-pam-libs
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

(define %ubuntu-pam-libs-24.04
  ;; 24.04's login chain no longer pulls in krb5/nsl/tirpc.
  (ubuntu-pam-libs
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

(define (ubuntu-pam-libs-for-version version)
  (cond ((string=? "22.04" version) %ubuntu-pam-libs-22.04)
        ((string=? "24.04" version) %ubuntu-pam-libs-24.04)
        (else #f)))

(define (host-ubuntu-pam-libs)
  "Return the host PAM closure as a list of absolute library file names,
or #f if the host is not Ubuntu 22.04/24.04."
  (and (string=? "ubuntu" (or (%os-release-field "ID") ""))
       (ubuntu-pam-libs-for-version (%os-release-field "VERSION_ID"))))

(define (noctalia-for-host)
  "Return the noctalia package for the machine this home environment is
being evaluated on: noctalia patched with the host's PAM closure on
Ubuntu releases with a known closure, plain noctalia anywhere else (see
the comment above).  Only for configs evaluated on the machine they run
on; Guix System configs pin the package instead."
  (let ((libs (host-ubuntu-pam-libs)))
    (if (and libs
             (file-exists? "/usr/lib/x86_64-linux-gnu/libpam.so.0"))
        (noctalia-with-host-pam noctalia libs)
        noctalia)))

(define (host-uses-systemd-activation?)
  "Return #t if D-Bus activation on this machine goes through the user
systemd manager -- that is, if systemd is the init.  The portals'
.service files carry SystemdService=, so on such a host activation
cannot start them inside the niri session and the session Shepherd has
to own their bus names instead (see home-niri-portal-services).  Like
noctalia-for-host, only meaningful for configs evaluated on the machine
they run on; Guix System configs pin @code{#:portals} instead."
  (file-exists? "/run/systemd/system"))

;; The session is managed by the host display manager (GDM on Ubuntu).
;; GDM runs /usr/local/bin/niri-session (host-side wrapper, see below),
;; which sources the Guix Home environment, waits for the greeter's
;; Xwayland to release :0, and then runs:
;;   niri --session
;; niri then spawns the user Shepherd (spawn-at-startup "shepherd"),
;; which starts noctalia and the other graphical services inside the
;; graphical session.
;;
;; Host-side wrapper (/usr/local/bin/niri-session); copied verbatim --
;; keep in sync when the host file changes:
;;   #!/bin/sh
;;   # setup-environment requires HOME_ENVIRONMENT to be set first (as
;;   # ~/.profile does).  Self-contained on purpose: GDM imports the
;;   # systemd user-manager environment only on hosts that have a
;;   # user-environment-generator; on hosts without one this source is
;;   # the only thing that puts the Guix Home profile on PATH.
;;   HOME_ENVIRONMENT="$HOME/.guix-home"
;;   [ -f "$HOME_ENVIRONMENT/setup-environment" ] && \
;;       . "$HOME_ENVIRONMENT/setup-environment"
;;   unset HOME_ENVIRONMENT
;;   # Ubuntu 22.04's user session runs PulseAudio (audio) and a
;;   # video-only PipeWire; the session Shepherd starts its own
;;   # PipeWire + WirePlumber + pipewire-pulse instead.  Stop the host
;;   # units (sockets included, so they cannot reactivate) to free the
;;   # pipewire-0 and pulse/native sockets in XDG_RUNTIME_DIR.
;;   systemctl --user stop pipewire.socket pipewire.service \
;;       pipewire-media-session.service pulseaudio.socket pulseaudio.service \
;;       2>/dev/null || true
;;   if [ -n "$DBUS_SESSION_BUS_ADDRESS" ]; then
;;       niri --session
;;   else
;;       dbus-run-session -- niri --session
;;   fi
;;   # niri exited: logind leaves processes behind (Ubuntu default
;;   # KillUserProcesses=no), so tear the session Shepherd down
;;   # explicitly. This stops the session services (noctalia, fcitx5)
;;   # and frees the Shepherd socket for the next login. Note: niri must
;;   # NOT be exec'd here, otherwise this cleanup never runs.
;;   herd stop root 2>/dev/null || true

(define (niri-noctalia-shepherd-service noctalia)
  "Return the Shepherd service that runs NOCTALIA."
  (shepherd-service
   (documentation "Start noctalia.")
   (provision '(noctalia))
   (requirement '(dbus graphical-session))
   (modules '((shepherd support)))
   (start
    #~(lambda args
        ((make-forkexec-constructor
          (list #$(file-append noctalia "/bin/noctalia"))
          #:log-file (in-vicinity %user-log-dir "noctalia.log")
          ;; Inherit the graphical session environment.
          #:environment-variables (environ))
         args)))
   (stop #~(make-kill-destructor))))

(define* (home-niri-noctalia-services #:key (noctalia (noctalia-for-host)))
  "Return the list of Home services that run NOCTALIA under a niri
session managed by the host display manager: a session Shepherd (started
by niri, not at login), a stub @code{dbus} service (the session bus is
provided by the host system) and noctalia itself.

NOCTALIA defaults to @code{noctalia-for-host}, the package for the
machine this home environment is evaluated on; that is only right for
configs evaluated on the machine they run on, so Guix System configs
pass plain noctalia instead (see the comment above)."
  (list
   (service home-shepherd-service-type
            (home-shepherd-configuration
             (auto-start? #f)
             (daemonize? #f)))

   ;; The session bus is provided by the host system (systemd/logind),
   ;; hence the stub instead of home-dbus-service-type.
   (simple-service 'dbus home-shepherd-service-type
                   (list (shepherd-service
                          (provision '(dbus))
                          (start #~(const #t))
                          (stop #~(const #f)))))

   ;; noctalia's home service, written out here rather than using
   ;; rosenthal's: that service type extends
   ;; home-graphical-session-service-type with 'wayland, and guix home
   ;; instantiates extension targets missing from its service list
   ;; (instantiate-missing-services in (gnu services)) -- keeping it
   ;; would materialize rosenthal's graphical-session and
   ;; wayland-display services alongside the ones from
   ;; home-niri-session-services.  The extension has no use here: the
   ;; wayland session plainly exists, niri is the compositor.
   (simple-service 'noctalia-profile home-profile-service-type
                   (list noctalia))
   (simple-service 'noctalia home-shepherd-service-type
                   (list (niri-noctalia-shepherd-service noctalia)))))

;;; Who owns the session's xdg-desktop-portal bus names depends on the
;;; host:
;;;
;;; On Guix System the session bus is a plain dbus-run-session daemon,
;;; which activates services from their Exec= lines, so the portals
;;; start on demand -- nothing to manage here.  Shepherd-managing them
;;; instead is actively harmful: a client that asks for the portal name
;;; before the Shepherd service got to it starts the activated instance,
;;; and the two frontends then race over the org.freedesktop.background
;;; Monitor name (xdg-desktop-portal's extra connection, requested with
;;; DO_NOT_QUEUE; the loser exits cleanly).  The Shepherd re-spawns its
;;; instance, blows past the respawn limit and gives up.
;;;
;;; On Ubuntu hosts D-Bus activation cannot start the session's portals:
;;; every portal D-Bus service file -- the host's and the profile's
;;; alike -- carries SystemdService=<name>.service, so activation goes
;;; through the user systemd manager, and a session started by the
;;; niri-session wrapper is not a systemd graphical session.
;;; xdg-desktop-portal-gnome.service fails its
;;; Requisite=graphical-session.target instantly, and
;;; xdg-desktop-portal.service is then killed when the backend it awaits
;;; never arrives; the names stay unowned until dbus-daemon gives up on
;;; the activation.  Every client that reads portal settings while
;;; starting -- GTK4 applications such as ghostty, Chromium and Electron
;;; ones such as Feishu -- blocks on that failed activation for ~90s
;;; (until the frontend unit hits its start timeout) before it can open
;;; a window.  Owning the bus names from the session Shepherd means no
;;; <name>.service is ever started.  niri-desktop-home-services picks
;;; this flavour automatically on hosts where systemd is the init (see
;;; host-uses-systemd-activation?), and Guix System configs pin
;;; @code{#:portals 'activation} for the reason given above
;;; noctalia-for-host.
;;;
;;; Either way the niri package ships niri-portals.conf (in the profile,
;;; hence in XDG_DATA_DIRS), which selects the GNOME backend by default
;;; and the GTK one for the interfaces the former does not implement.

(define (home-niri-portal-services)
  "Return the Home services that run the niri session's
xdg-desktop-portal stack from the Guix profile: the portal frontend
and its GNOME and GTK backends (see the comment above).  For hosts
whose D-Bus activation cannot start the portals -- those with systemd
as init; elsewhere the session bus activates them itself."
  (list
   (simple-service 'niri-portals home-shepherd-service-type
                   (list
                    (shepherd-service
                     (provision '(xdg-desktop-portal))
                     (requirement '(graphical-session))
                     (start #~(make-forkexec-constructor
                               (list #$(file-append xdg-desktop-portal
                                                    "/libexec/xdg-desktop-portal"))))
                     (stop #~(make-kill-destructor)))
                    (shepherd-service
                     (provision '(xdg-desktop-portal-gnome))
                     (requirement '(graphical-session))
                     (start #~(make-forkexec-constructor
                               (list #$(file-append xdg-desktop-portal-gnome
                                                    "/libexec/xdg-desktop-portal-gnome"))))
                     (stop #~(make-kill-destructor)))
                    (shepherd-service
                     (provision '(xdg-desktop-portal-gtk))
                     (requirement '(graphical-session))
                     (start #~(make-forkexec-constructor
                               (list #$(file-append xdg-desktop-portal-gtk
                                                    "/libexec/xdg-desktop-portal-gtk"))))
                     (stop #~(make-kill-destructor)))))))

;;; XWayland and the session's display targets are session Shepherd
;;; services, provided here instead of by rosenthal's
;;; home-graphical-session-service-type.
;;;
;;; niri's built-in Xwayland integration spawns xwayland-satellite on
;;; demand, on the first X client connection.  That is too late for
;;; fcitx5: its XIM frontend connects to X once at startup and does not
;;; retry, so X must already be up when fcitx5 starts, or X11 apps get
;;; no input method.  The satellite therefore runs as a Shepherd service
;;; -- kept alive by respawn, with a start method that re-spawns it
;;; until it survives.  The retry matters right after login: the display
;;; manager's greeter may still own :0 with its own Xwayland, which
;;; makes the satellite exit at once, and five quick respawns would trip
;;; the respawn limit and disable the service.  niri's own spawner is
;;; disabled with "xwayland-satellite { off }" (see the niri dotfiles),
;;; so there is exactly one satellite and the display number stays :0.
;;;
;;; x11-display reports ready only once the satellite is running -- that
;;; is, once the session's Xwayland holds :0 -- and exports DISPLAY=:0.
;;; rosenthal's x11-display instead scans /tmp/.X11-unix for the first
;;; X[0-9]+ with (access? name O_RDWR), which the greeter's socket
;;; satisfies during login: fcitx5 (requirement '(dbus
;;; graphical-session), not configurable) would then connect to the
;;; greeter's X, fail authorization and never retry.  Providing the
;;; display targets here makes the chain
;;;   fcitx5 -> graphical-session -> x11-display -> xwayland-satellite
;;; wait for the session's own X to exist.

(define (niri-xwayland-satellite-service)
  "Return the Shepherd service that runs xwayland-satellite on display
:0.  Its start method retries the spawn until the satellite survives,
which takes the display from a display manager's greeter when that is
still shutting down after login."
  (shepherd-service
   (documentation "Run xwayland-satellite on display :0.")
   (provision '(xwayland-satellite))
   (requirement '(wayland-display))
   (respawn? #t)
   (start
    #~(lambda args
        (define spawn
          (make-forkexec-constructor
           (list #$(file-append xwayland-satellite
                                "/bin/xwayland-satellite")
                 ":0")
           ;; Inherit the session environment; the satellite needs
           ;; WAYLAND_DISPLAY and finds Xwayland on PATH.
           #:environment-variables (environ)))
        (define (alive? process)
          (catch 'system-error
            (lambda () (kill (process-id process) 0) #t)
            (lambda _ #f)))
        ;; Xwayland exits as soon as it is denied the display, so give
        ;; each attempt a moment, then retry until the satellite stays.
        (let retry ((attempt 0))
          (let ((process (spawn args)))
            (sleep 1.5)
            (cond ((alive? process) process)
                  ((< attempt 20) (retry (+ attempt 1)))
                  (else #f))))))
   (stop #~(make-kill-destructor))))

(define (niri-session-display-services)
  "Return the Shepherd services that provide the session's display
targets: wayland-display (a marker for the compositor's socket, taken
from WAYLAND_DISPLAY), x11-display (ready only once the session's
XWayland is up, see niri-xwayland-satellite-service) and
graphical-session, which requires both, is in turn required by fcitx5,
noctalia and the portals, and hands the ready session's display
environment to the D-Bus daemon for its activated services."
  (list
   (shepherd-service
    (documentation "Wayland display of the session's compositor.")
    (provision '(wayland-display))
    (start #~(lambda args (getenv "WAYLAND_DISPLAY")))
    (stop #~(lambda (_)
              (unsetenv "WAYLAND_DISPLAY")
              #f)))
   (shepherd-service
    (documentation "X11 display of the session, from xwayland-satellite.")
    (provision '(x11-display))
    ;; The satellite's start method returns only once its Xwayland
    ;; survives on :0, so that completion is the readiness signal -- not
    ;; a socket scan, which any accessible socket satisfies, be it the
    ;; greeter's or a stale one.
    (requirement '(wayland-display xwayland-satellite))
    (start #~(lambda args
               (setenv "DISPLAY" ":0")
               ":0"))
    (stop #~(lambda (_)
              (unsetenv "DISPLAY")
              #f)))
   (shepherd-service
    (documentation
     "Service target to indicate a graphical session is ready.")
    (provision '(graphical-session))
    (requirement '(wayland-display x11-display))
    ;; D-Bus-activated services inherit dbus-daemon's environment, not
    ;; the session's -- the daemon is started by dbus-run-session
    ;; before the compositor's socket and X exist.  Hand it the ready
    ;; session's environment, or e.g. Guix System's activated portal
    ;; backends come up without a display to talk to.
    (start #~(lambda args
               (system* #$(file-append dbus
                                       "/bin/dbus-update-activation-environment")
                        "WAYLAND_DISPLAY" "DISPLAY" "XDG_CURRENT_DESKTOP"
                        "XDG_SESSION_TYPE")
               #t))
    (stop #~(const #f)))))

(define (home-niri-session-services)
  "Return the Home services that provide the niri session's display
targets and its XWayland: the @command{xwayland-satellite} Shepherd
service, run on display :0, and the wayland-display, x11-display and
graphical-session services that report the session ready only once that
X server is up (see the comment above)."
  (list
   (simple-service 'niri-xwayland home-shepherd-service-type
                   (list (niri-xwayland-satellite-service)))
   (simple-service 'niri-session-display home-shepherd-service-type
                   (niri-session-display-services))))

;; The Guix System counterpart of the host-side wrapper above, for
;; greetd-based systems (see env/guix/os/lappie.scm): the session
;; command passed to tuigreet's --cmd.  Guix compiles the record into a
;; wrapper that sets XDG_SESSION_TYPE and XDG_RUNTIME_DIR (greetd's PAM
;; stack has no pam_elogind, so the worker does not set them itself;
;; passing a raw string to --cmd skips that wrapper).  bash -l then
;; sources /etc/profile and ~/.bash_profile, which pull in the Guix
;; Home environment and ~/.profile.d, and dbus-run-session provides
;; the session bus.
(define (niri-greetd-user-session)
  (greetd-user-session
   (command (file-append bash "/bin/bash"))
   (command-args '("-l" "-c" "exec dbus-run-session -- niri --session"))
   (xdg-session-type "wayland")))
