(define-module (uraj home basic-sys)
  #:use-module (gnu home)
  #:use-module (gnu home services)
  #:use-module (gnu home services shells)
  #:use-module (gnu packages)
  #:use-module (gnu services)
  #:use-module (guix gexp)
  #:use-module (uraj common basic-services)
  #:use-module (uraj utils file path)
  #:export (basic-sys-home-services))

;; Package lists in (uraj home ...) are procedures, not variables: resolving
;; specifications at load time scans every -L module, re-entering modules
;; still being loaded, e.g. (uraj system desktop) before (uraj home niri)
;; has defined niri-desktop-home-services.
(define (basic-sys-packages)
  (specifications->packages
   '(;; UI
     "bash-completion"          ; completions for git, fd, ... (see .bashrc.d)
     "tmux"
     ;; Data.
     "direnv"
     "fd"
     "git"
     "git-lfs"
     "ripgrep"
     "rsync"
     "vim"
     "zip"
     "7zip"
     ;; Networking.
     "bind:utils"              ; dig, host, nslookup; no DNS server output
     "tcpdump"
     "netcat-openbsd"          ; nc
     "iproute2"                ; ip, ss
     "iputils"                 ; ping, tracepath
     "traceroute"
     "mtr"
     "curl"
     "wget"
     ;; Security.
     "age"
     "bubblewrap"
     "password-store"
     "sshpass"
     ;; System status.
     "htop"
     "ncdu"
     ;; Utils.
     "inotify-tools"
     "nss-certs"                ; Without this git clone would have ssl unknown certs errors.
     "python"
     "pv"
     "xdg-utils")))

(define (basic-sys-home-services)
  (append
   (list
    (simple-service 'basic-sys-packages
                    home-profile-service-type
                    (basic-sys-packages))
    ;; Appended to Guix Home's ~/.profile, after setup-environment, so that
    ;; every reader of ~/.profile (not only bash login shells) gets the
    ;; ~/.profile.d snippets.  Keep the snippets POSIX sh.
    (simple-service 'profile-d
                    home-shell-profile-service-type
                    (list (plain-file "profile-d.sh" "\
for profile in \"$HOME\"/.profile.d/*.sh; do
    [ -r \"$profile\" ] && . \"$profile\"
done
unset profile
"))))
   (my-dotfiles-services
    (list (project-path "env/dotfiles/common")))))
