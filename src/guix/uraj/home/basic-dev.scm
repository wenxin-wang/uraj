(define-module (uraj home basic-dev)
  #:use-module (gnu home)
  #:use-module (gnu home services)
  #:use-module (gnu packages)
  #:use-module (gnu services)
  #:export (basic-dev-home-services))

(define basic-dev-packages
  (specifications->packages
   '("direnv"
     "fd"
     "ripgrep"
     "age"
     "inotify-tools"
     "git"
     "vim")))

(define (basic-dev-home-services)
  (list
   (simple-service 'basic-dev-packages
                   home-profile-service-type
                   basic-dev-packages)))
