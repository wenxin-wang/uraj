(define-module (uraj home basic-dev)
  #:use-module (gnu home)
  #:use-module (gnu home services)
  #:use-module (gnu packages)
  #:use-module (gnu services)
  #:use-module (guix gexp)
  #:use-module (uraj common basic-services)
  #:use-module (uraj utils file path)
  #:export (basic-dev-home-services))

(define basic-dev-packages
  (specifications->packages
   '("bash-completion"          ; completions for git, fd, ... (see .bashrc.d)
     "direnv"
     "fd"
     "ripgrep"
     "age"
     ;; OpenPGP smart cards (YubiKey/CanoKey), commit signing and the
     ;; gpg-agent SSH agent.  Keep a terminal pinentry here so basic-dev also
     ;; works on machines without a desktop environment.
     "gnupg"
     "pinentry-tty"
     "inotify-tools"
     "git"
     "nss-certs"                ; Without this git clone would have ssl unknown certs errors.
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
                    basic-dev-packages)
    ;; GnuPG rejects an overly permissive home directory.  home-dotfiles may
    ;; have to create ~/.gnupg on a fresh machine, so enforce its required
    ;; private mode during every Home activation.
    (simple-service 'gnupg-home-permissions
                    home-activation-service-type
                    #~(let ((gnupg-home
                             (string-append (getenv "HOME") "/.gnupg")))
                        (unless (file-exists? gnupg-home)
                          (mkdir gnupg-home #o700))
                        (chmod gnupg-home #o700))))
   (my-dotfiles-services (list (project-path "env/dotfiles/common")))))
