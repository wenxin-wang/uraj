;;; Headless role: console login, wired networking, and a basic user Home.
(define-module (uraj system server)
  #:use-module (gnu)
  #:use-module (gnu home)
  #:use-module (gnu home services)
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu services networking)
  #:use-module (guix gexp)
  #:use-module (uraj home basic-sys)
  #:use-module (uraj system base)
  #:use-module (uraj system home)
  #:use-module (uraj utils file path)
  #:export (%server-base-os server-home-environment))

(define server-home-environment
  (home-environment
   (services
    (cons (simple-service
           'trusted-guix-channels
           home-files-service-type
           `((".config/guix/trusted-channels.scm"
              ,(local-file
                (project-path "env/guix/trusted-channels.scm")
                "trusted-channels.scm"))))
          (basic-sys-home-services)))))

(define %server-base-os
  (operating-system
    (inherit %base-os)
    (host-name "server")
    (services
     (cons* (service dhcpcd-service-type)
            ;; Activate the same Home on installed systems and live images.
            (service guix-home-with-environment-service-type
                     (list (list "wenxin" server-home-environment)))
            (service greetd-service-type
              (base-greetd-configuration
               (lambda (vt) %greetd-console-session)))
            (modify-services (operating-system-user-services %base-os)
              (delete mingetty-service-type))))))
