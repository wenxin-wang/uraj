(define-module (uraj home basic-dev)
  #:use-module (gnu home)
  #:use-module (gnu home services)
  #:use-module (gnu packages)
  #:use-module (gnu services)
  #:use-module (uraj common basic-services)
  #:use-module (uraj utils file path)
  #:export (basic-dev-home-services))

(define basic-dev-packages
  (specifications->packages
   '("bash-completion"          ;completions for git, fd, ... (see .bashrc.d)
     "direnv"
     "fd"
     "ripgrep"
     "age"
     "inotify-tools"
     "git"
     "vim"
     ;; System status.
     "htop"
     ;; Python
     "uv")))

(define (basic-dev-home-services)
  (append
   (list
    (simple-service 'basic-dev-packages
                    home-profile-service-type
                    basic-dev-packages))
   (my-dotfiles-services (list (project-path "env/dotfiles/common")))))
