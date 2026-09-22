(define-module (uraj home niri)
  #:use-module (gnu home services)
  #:use-module (gnu home services sound)
  #:use-module (gnu packages)
  #:use-module (gnu services)
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
     "xorg-server-xwayland"      ;X11 apps (fcitx5 XIM)
     "xwayland-satellite")))     ;niri spawns it for X11 support

;;; noctalia <= 5.0.0-beta.8 registered the session lock screen with
;;; text-input-v3, which could leave fcitx5 without input for apps
;;; that existed before the lock (upstream #3993, fixed in
;;; v5.0.0-beta.9).  Should it ever regress, the workaround is a brief
;;; focus round trip to the launcher (Mod+D).

(define (niri-desktop-home-services)
  "Return the Home services for a niri desktop: the niri + noctalia
session services, PipeWire audio, fcitx5, the shared dotfiles and the
base services."
  (append
   (list
    (simple-service 'niri-desktop-packages
                    home-profile-service-type
                    niri-desktop-packages)
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
   ;; itself, patched with the host's PAM stack where needed.
   (home-niri-noctalia-services)
   (basic-desktop-home-services)))
