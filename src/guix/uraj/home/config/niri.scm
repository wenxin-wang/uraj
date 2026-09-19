(define-module (uraj home config niri)
  #:use-module (gnu home)
  #:use-module (gnu home services)
  #:use-module (gnu home services sound)
  #:use-module (gnu packages)
  #:use-module (gnu packages fcitx5)
  #:use-module (gnu services)
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
