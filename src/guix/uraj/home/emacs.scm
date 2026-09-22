(define-module (uraj home emacs)
  #:use-module (gnu home)
  #:use-module (gnu home services)
  #:use-module (gnu packages)
  #:use-module (gnu services)
  #:export (emacs-home-services))

(define emacs-packages
  (specifications->packages
   `(,(if (getenv "WAYLAND_DISPLAY")
                 "emacs-pgtk"
                 "emacs"))))

(define (emacs-home-services)
  (list
   (simple-service 'emacs-packages
                   home-profile-service-type
                   emacs-packages)))
