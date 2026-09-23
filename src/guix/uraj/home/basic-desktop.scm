(define-module (uraj home basic-desktop)
  #:use-module (gnu home)
  #:use-module (gnu home services)
  #:use-module (gnu packages)
  #:use-module (gnu packages fcitx5)
  #:use-module (gnu services)
  #:use-module (guix gexp)
  #:use-module (rosenthal services desktop)
  #:use-module (uraj common basic-services)
  #:use-module (uraj home basic-dev)
  #:use-module (uraj home emacs)
  #:use-module (uraj packages basic-packages)
  #:use-module (uraj packages input-methods)
  #:use-module (uraj packages terminals)
  #:use-module (uraj utils file path)
  #:export (basic-desktop-home-services))

(define basic-desktop-packages
  (cons* glibc-common-locales
         ghostty                        ;terminal emulator
         (specifications->packages
          '("font-jigmo"
            "font-jetbrains-mono"
            "font-sarasa-gothic"
            "font-nerd-symbols"))))

(define (merged-terminfo-directory packages)
  "Return a directory merging the `share/terminfo' trees of PACKAGES, each
of which must install one.  The system ncurses on a foreign distro only
searches ~/.terminfo and its own database, not Guix profiles, so terminal
entries such as xterm-ghostty must be linked there to be usable in ssh
sessions.  Merging (rather than linking a single package's directory) keeps
the link extensible: add another terminal package to the list when needed."
  (directory-union "terminfo"
                   (map (lambda (package)
                          (file-append package "/share/terminfo"))
                        packages)))

(define (basic-desktop-home-services)
  "Return the Home services shared by all desktop sessions: the
basic-desktop packages, fcitx5, the shared dotfiles and the base
services."
  (append
   (list
    (simple-service 'basic-desktop-packages
                    home-profile-service-type
                    basic-desktop-packages)

    ;; 见 merged-terminfo-directory：其它终端包也可以加进这个列表。
    (simple-service 'terminfo
                    home-files-service-type
                    `((".terminfo"
                       ,(merged-terminfo-directory (list ghostty)))))

    (service home-fcitx5-service-type
             (home-fcitx5-configuration
              ;; fcitx5-replace (see (uraj packages input-methods)): start
              ;; with --replace.
              (fcitx5 fcitx5-replace)
              ;; 全局导出 GTK_IM_MODULE=fcitx：XWayland 下的 GTK/Chromium
              ;; 应用（飞书、Cursor 等）需要它加载 fcitx5 immodule，这是
              ;; fcitx5 官方 wiki 对 XWayland 应用的推荐配置。由此产生的
              ;; wayland-diagnose-other 登录通知已在 fcitx5 的
              ;; notifications.conf 里静音（见 dotfiles 模板）
              (wayland-frontend? #f)
              (themes (list fcitx5-material-color-theme))
              (input-method-editors (list fcitx5-rime)))))
   (my-dotfiles-services (list (project-path "env/dotfiles/desktop")))
   (basic-dev-home-services)
   (emacs-home-services)
   %base-home-services))
