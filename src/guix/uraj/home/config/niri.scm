(define-module (uraj home config niri)
  #:use-module (gnu home)
  #:use-module (gnu home services)
  #:use-module (gnu home services sound)
  #:use-module (gnu packages)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages fcitx5)
  #:use-module (gnu services)
  #:use-module (guix build-system trivial)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (rosenthal services desktop)
  #:use-module (uraj common basic-packages)
  #:use-module (uraj common basic-services)
  #:use-module (uraj home services noctalia)
  #:use-module (uraj utils file path)
  #:export (niri-desktop-home-services))

;;; One-stop Home configuration for a niri desktop session.  The
;;; packages ride along with the services: the profile extension below
;;; is what the home-environment 'packages' field expands to anyway,
;;; so configs only need to add (niri-desktop-home-services) to their
;;; services and the whole desktop comes with it.

(define niri-desktop-packages
  (cons* glibc-common-locales
         (specifications->packages
          '("swappy"                    ;screenshot editing (Print flow)
            "grim"                      ;screenshot capture (Print/Mod+Print flow)
            "qtwayland"                 ;Qt Wayland platform plugin
            "niri"
            "wezterm"                   ;terminal emulator
            "wl-clipboard"
            "xdg-desktop-portal-gnome"  ;screencast/screenshots
            "xdg-desktop-portal-gtk"
            "xorg-server-xwayland"      ;X11 apps (fcitx5 XIM)
            "xwayland-satellite"))))    ;niri spawns it for X11 support

;;; fcitx5 must start with --replace.  A plain start exits with status 0
;;; when another instance owns the D-Bus name (e.g. a stray left by the
;;; tray "Restart" action, which double-forks), so Shepherd's respawn
;;; would re-spawn it until the respawn limit disables the service.
;;; With --replace the new instance takes the name and the stray exits.
(define fcitx5-replace
  (package
    (name "fcitx5-replace")
    (version (package-version fcitx5))
    (source #f)
    (build-system trivial-build-system)
    (arguments
     (list
      #:modules '((guix build utils))
      #:builder
      #~(begin
          (use-modules (guix build utils))
          (let ((bin (string-append #$output "/bin")))
            (mkdir-p bin)
            (call-with-output-file (string-append bin "/fcitx5")
              (lambda (port)
                (format port "#!~a~%exec ~a -r \"$@\"~%"
                        #$(file-append bash-minimal "/bin/bash")
                        #$(file-append fcitx5 "/bin/fcitx5"))))
            (chmod (string-append bin "/fcitx5") #o755)))))
    (propagated-inputs (list fcitx5))
    (home-page (package-home-page fcitx5))
    (synopsis "fcitx5 launcher that replaces a running instance")
    (description
     "Starts fcitx5 with @code{--replace}, so a fresh instance takes the
D-Bus name from a stray one instead of exiting.")
    (license (package-license fcitx5))))

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
    ;; these services (see (uraj home services noctalia)).
    (service home-pipewire-service-type)

    (service home-fcitx5-service-type
             (home-fcitx5-configuration
              ;; fcitx5-replace: start with --replace, see above.
              (fcitx5 fcitx5-replace)
              ;; 全局导出 GTK_IM_MODULE=fcitx：XWayland 下的 GTK/Chromium
              ;; 应用（飞书、Cursor 等）需要它加载 fcitx5 immodule，这是
              ;; fcitx5 官方 wiki 对 XWayland 应用的推荐配置。由此产生的
              ;; wayland-diagnose-other 登录通知已在 fcitx5 的
              ;; notifications.conf 里静音（见 dotfiles 模板）
              (wayland-frontend? #f)
              (themes (list fcitx5-material-color-theme))
              (input-method-editors (list fcitx5-rime)))))
   (my-dotfiles-services (list (project-path "env/dotfiles/common")))
   ;; The niri + noctalia session: a session Shepherd (started by
   ;; "niri --session", not at login), a stub dbus service (the session
   ;; bus comes from the host system or dbus-run-session) and noctalia
   ;; itself, patched with the host's PAM stack where needed.
   (home-niri-noctalia-services)
   %base-home-services))
