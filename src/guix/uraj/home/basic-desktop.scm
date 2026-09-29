(define-module (uraj home basic-desktop)
  #:use-module (gnu home)
  #:use-module (gnu home services)
  #:use-module (gnu packages)
  #:use-module (gnu packages admin)
  #:use-module (gnu packages base)
  #:use-module (gnu packages fcitx5)
  #:use-module (gnu services)
  #:use-module (guix gexp)
  #:use-module (nongnu packages mozilla)
  #:use-module (rosenthal services desktop)
  #:use-module (uraj common basic-services)
  #:use-module (uraj home basic-dev)
  #:use-module (uraj home emacs)
  #:use-module (uraj home llm)
  #:use-module (uraj packages basic-packages)
  #:use-module (uraj packages input-methods)
  #:use-module (uraj packages rime)
  #:use-module (uraj packages terminals)
  #:use-module (uraj utils file path)
  #:export (basic-desktop-home-services))

(define basic-desktop-packages
  (cons* glibc-common-locales
         ghostty                        ;terminal emulator
         firefox                        ;Mozilla Firefox from the Nonguix channel
         (specifications->packages
          '("font-jigmo"
            "font-jetbrains-mono"
            "font-sarasa-gothic"
            "font-nerd-symbols"
            ;; pinentry-auto selects this in Wayland/X11 sessions; basic-dev
            ;; supplies pinentry-tty for console and SSH sessions.
            "pinentry-qt"
            ;; Graphical SSH password prompts outside terminal sessions.  It
            ;; works outside Plasma; its Qt/KDE Frameworks dependencies are
            ;; part of the package closure.
            "ksshaskpass"
            ;; For general desktop settings
            "evtest"))))

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

(define rime-user-data-directory ".local/share/fcitx5/rime")

(define rime-ice-data-home-files
  (map (lambda (name)
         (list (string-append rime-user-data-directory "/" name)
               (file-append rime-ice "/share/rime-ice/" name)))
       rime-ice-data-files))

(define (rime-ice-build-refresh-service default-custom-path)
  "Return an activation service that, when the rime-ice data or
DEFAULT-CUSTOM-PATH changed since the last activation or the compiled
default configuration is missing, removes the Rime
build directory under ~/.local/share/fcitx5/rime and restarts fcitx5.

Rime recompiles a configuration only if its source file's mtime changed,
but files deployed from the store have a frozen mtime (epoch + 1).  After
a reconfigure installs new rime-ice data (or a new default.custom.yaml),
deployment would otherwise silently keep using the stale build until one
deletes the build directory by hand; the content-addressed store paths
below change exactly when the contents do, so they serve as the trigger.

Deleting the build is not enough while fcitx5 runs: Rime keeps the
configuration it deployed in memory and reloads it only at startup, and
a reconfigure does not restart running services -- the home shepherd
merely records the replacement.  So bounce the fcitx5 service too, but
only when the home shepherd is up and fcitx5 is running, to avoid
starting fcitx5 outside a graphical session (where it would fail and
burn the respawn limit)."
  (simple-service 'rime-ice-build-refresh
                  home-activation-service-type
                  (with-imported-modules '((guix build utils))
                    #~(begin
                        (use-modules (guix build utils)
                                     (ice-9 popen)
                                     (ice-9 textual-ports))
                        (define herd
                          #$(file-append shepherd-for-home "/bin/herd"))
                        (define env
                          #$(file-append coreutils "/bin/env"))
                        (define (shepherd-socket)
                          (string-append
                           (or (getenv "XDG_RUNTIME_DIR")
                               (format #f "/run/user/~a" (getuid)))
                           "/shepherd/socket"))
                        (define (fcitx5-running?)
                          ;; herd's messages are localized, so force the C
                          ;; locale to make the match below reliable.
                          (let* ((pipe (open-pipe* OPEN_READ env
                                                   "LC_ALL=C" herd
                                                   "--socket" (shepherd-socket)
                                                   "status" "fcitx5"))
                                 (output (get-string-all pipe)))
                            (close-pipe pipe)
                            (string-contains output "It is running")))
                        (let* ((home (getenv "HOME"))
                               (stamp
                                (string-append home
                                               "/.cache/uraj/rime-build.stamp"))
                               (build
                                (string-append home "/"
                                               #$rime-user-data-directory
                                               "/build"))
                               (fingerprint
                                (string-append
                                 #$(file-append rime-ice "/share/rime-ice")
                                 "\n"
                                 #$(local-file default-custom-path)
                                 "\n"))
                               (previous
                                (and (file-exists? stamp)
                                     (call-with-input-file stamp
                                       get-string-all))))
                          (when (or (not (equal? previous fingerprint))
                                    (not (file-exists?
                                          (string-append build "/default.yaml"))))
                            (when (file-exists? build)
                              (delete-file-recursively build))
                            (when (and (file-exists? (shepherd-socket))
                                       (fcitx5-running?))
                              (unless (zero? (system* herd
                                                      "--socket" (shepherd-socket)
                                                      "restart" "fcitx5"))
                                (error "Failed to restart fcitx5 after clearing Rime cache")))
                            ;; Record invalidation only after a successful
                            ;; restart, or leave compilation to next login
                            ;; when fcitx5 is not running.
                            (mkdir-p (dirname stamp))
                            (call-with-output-file stamp
                              (lambda (port)
                                (display fingerprint port)))))))))

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

    ;; 雾凇拼音（rime-ice）的数据文件；默认方案由 dotfiles 里的
    ;; default.custom.yaml 补丁启用。
    (simple-service 'rime-ice-data
                    home-files-service-type
                    rime-ice-data-home-files)

    ;; 数据或补丁变化时清掉旧 build/ 并重启 fcitx5，强制 rime 重新部署
    ;;（见 docstring）。
    (rime-ice-build-refresh-service
     (project-path
      "env/dotfiles/desktop/fcitx/.local/share/fcitx5/rime/default.custom.yaml"))

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
   (llm-home-services)
   %base-home-services))
