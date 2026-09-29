(define-module (uraj home basic-sys)
  #:use-module (gnu home)
  #:use-module (gnu home services)
  #:use-module (gnu packages)
  #:use-module (gnu services)
  #:use-module (uraj common basic-services)
  #:use-module (uraj utils file path)
  #:export (basic-sys-home-services))

(define basic-sys-packages
  (specifications->packages
   '(;; UI
     "bash-completion"          ; completions for git, fd, ... (see .bashrc.d)
     "tmux"
     ;; Data.
     "direnv"
     "fd"
     "git"
     "ripgrep"
     "rsync"
     "vim"
     ;; Security.
     "age"
     "bubblewrap"
     ;; System status.
     "htop"
     "ncdu"
     ;; Utils.
     "inotify-tools"
     "nss-certs"                ; Without this git clone would have ssl unknown certs errors.
     "pv"
     "xdg-utils")))

(define (basic-sys-home-services)
  (append
   (list
    (simple-service 'basic-sys-packages
                    home-profile-service-type
                    basic-sys-packages))
   (my-dotfiles-services
    (list (project-path "env/dotfiles/common")))))
