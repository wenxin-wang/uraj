(define-module (uraj home niri)
  #:use-module (gnu home services)
  #:use-module (gnu home services shepherd)
  #:use-module (gnu home services sound)
  #:use-module (gnu packages)
  #:use-module (gnu packages polkit)
  #:use-module (gnu services)
  #:use-module (guix gexp)
  #:use-module (uraj home basic-desktop)
  #:use-module (uraj packages window-managers)
  #:export (niri-desktop-home-services))

;;; One-stop Home configuration for a niri desktop session.  The
;;; packages ride along with the services: the profile extension below
;;; is what the home-environment 'packages' field expands to anyway,
;;; so configs only need to add (niri-desktop-home-services) to their
;;; services and the whole desktop comes with it.

(define niri-desktop-packages
  (specifications->packages
   '("swappy"                    ;screenshot editing (Print flow)
     "grim"                      ;screenshot capture (Print/Mod+Print flow)
     "qtwayland"                 ;Qt Wayland platform plugin
     "niri"
     "wl-clipboard"
     "xdg-desktop-portal-gnome"  ;screencast/screenshots
     "xdg-desktop-portal-gtk"
     "xorg-server-xwayland"      ;Xwayland, exec'd by xwayland-satellite
     "xwayland-satellite")))     ;X11 support, run by the session Shepherd

(define %niri-polkit-agent-service
  (shepherd-service
   (documentation "Run a graphical Polkit authentication agent for niri.")
   (provision '(polkit-agent))
   (requirement '(dbus graphical-session))
   (modules '((shepherd support)))
   (start #~(make-forkexec-constructor
             (list #$(file-append
                      polkit-gnome
                      "/libexec/polkit-gnome-authentication-agent-1"))
             #:log-file
             (in-vicinity %user-log-dir "polkit-agent.log")
             #:environment-variables (environ)))
   (stop #~(make-kill-destructor))))

;;; noctalia <= 5.0.0-beta.8 registered the session lock screen with
;;; text-input-v3, which could leave fcitx5 without input for apps
;;; that existed before the lock (upstream #3993, fixed in
;;; v5.0.0-beta.9).  Should it ever regress, the workaround is a brief
;;; focus round trip to the launcher (Mod+D).

(define* (niri-desktop-home-services
          #:key (noctalia (noctalia-for-host))
                (portals (if (host-uses-systemd-activation?)
                             'shepherd
                             'activation)))
  "Return the Home services for a niri desktop: the niri + noctalia
session services, the xdg-desktop-portal stack, PipeWire audio, fcitx5,
the shared dotfiles and the base services.

NOCTALIA and PORTALS both default to the choice for the machine this
home environment is evaluated on -- @code{noctalia-for-host} and
@code{host-uses-systemd-activation?} -- which is right for configs that
run on the machine they are evaluated on (@command{guix home
reconfigure} ones).  Guix System configs build their home environment on
some other machine and must pin both: plain noctalia and
@code{#:portals 'activation} (see (uraj packages window-managers) and
(uraj system desktop))."
  (append
   (list
    (simple-service 'niri-desktop-packages
                    home-profile-service-type
                    niri-desktop-packages)
    ;; NetworkManager operations such as creating the first connection
    ;; require Polkit authorization.  Noctalia supplies NM's secret agent
    ;; (the Wi-Fi password prompt), but it is not a Polkit authentication
    ;; agent; without this service the request is denied after the password
    ;; is submitted and the UI appears to do nothing.
    (simple-service 'niri-polkit-agent
                    home-shepherd-service-type
                    (list %niri-polkit-agent-service))
    ;; The session's audio stack: PipeWire + WirePlumber + PipeWire's
    ;; PulseAudio compatibility layer.  Versions match the client
    ;; libraries noctalia links against.  On Ubuntu hosts the
    ;; niri-session wrapper stops the host's audio user units before
    ;; starting niri so the sockets in XDG_RUNTIME_DIR are free for
    ;; these services (see (uraj packages window-managers)).
    (service home-pipewire-service-type))
   ;; The niri + noctalia session: a session Shepherd (started by
   ;; "niri --session", not at login), a stub dbus service (the session
   ;; bus comes from the host system or dbus-run-session) and noctalia
   ;; itself, as noctalia-for-host selects it.
   (home-niri-noctalia-services #:noctalia noctalia)
   ;; The xdg-desktop-portal stack, session-Shepherd-managed on hosts
   ;; where systemd activation cannot start it; elsewhere the session
   ;; bus activates the portals itself (see (uraj packages
   ;; window-managers)).
   (if (eq? portals 'shepherd)
       (home-niri-portal-services)
       '())
   ;; XWayland on :0 as a session Shepherd service, plus the session's
   ;; display targets (wayland-display, x11-display, graphical-session)
   ;; that report the session ready only once that X server is up:
   ;; X11 apps need a live X, and fcitx5's XIM frontend connects to X
   ;; only at startup (see (uraj packages window-managers)).
   (home-niri-session-services)
   (basic-desktop-home-services)))
