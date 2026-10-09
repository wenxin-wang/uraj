;;; Headless role: console login, wired networking, and a basic user Home.
;;; elogind provides /run/user/$UID for every PAM login (greetd and ssh),
;;; which Guix Home's on-first-login and user shepherd rely on.
(define-module (uraj system server)
  #:use-module (gnu)
  #:use-module (gnu home)
  #:use-module (gnu home services)
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu services desktop)
  #:use-module (gnu services networking)
  #:use-module (guix gexp)
  #:use-module (uraj common context)
  #:use-module (uraj home basic-sys)
  #:use-module (uraj packages elogind)
  #:use-module (uraj services desktop)
  #:use-module (uraj system base)
  #:use-module (uraj system home)
  #:use-module (uraj utils file path)
  #:export (server-base-os server-home-environment))

(define* (server-home-environment user #:key (extra-services '()))
  (parameterize ((%home-target (guix-system-home-target user)))
    (home-environment
     (services
      (cons (simple-service
             'trusted-guix-channels
             home-files-service-type
             `((".config/guix/trusted-channels.scm"
                ,(local-file
                  (project-path "env/guix/trusted-channels.scm")
                  "trusted-channels.scm"))))
            (append (basic-sys-home-services) extra-services))))))

(define* (server-base-os main-user ssh-key #:key (home-services '()))
  "Return the headless role administered by MAIN-USER (see
main-user-account), who also owns the embedded Home.  SSH-KEY is as for
base-os."
  (let ((base (base-os main-user ssh-key)))
    (operating-system
      (inherit base)
      (host-name "server")
      (services
       (cons* (service dhcpcd-service-type)
              ;; Activate the same Home on installed systems and live images.
              (service guix-home-with-environment-service-type
                       (list (list (user-account-name main-user)
                                   (server-home-environment
                                    main-user #:extra-services home-services))))
              (service elogind-service-type
                (elogind-configuration
                  (elogind elogind-with-shepherd-kexec)))
              (service greetd-with-elogind-service-type
                (base-greetd-configuration
                 (lambda (vt) %greetd-console-session)))
              (modify-services (operating-system-user-services base)
                (delete mingetty-service-type)))))))
