(define-module (uraj home services noctalia)
  #:use-module (gnu home services)
  #:use-module (gnu home services shepherd)
  #:use-module (gnu services)
  #:use-module (gnu services configuration)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:use-module (srfi srfi-1)
  #:use-module ((rosenthal home services desktop) #:prefix rosenthal:)
  #:autoload (rosenthal packages wm) (noctalia)
  #:export (home-noctalia-configuration
            home-noctalia-service-type))

;;; Like the Rosenthal channel's home-noctalia-service-type, but with
;;; support for extra environment variables (e.g. to LD_PRELOAD the
;;; host's PAM stack into noctalia's screen locker).  It inherits the
;;; upstream service type and replaces its Shepherd extension; drop this
;;; module if upstream ever gains an 'environment-variables' field.

(define-configuration/no-serialization home-noctalia-configuration
  (noctalia
   (file-like noctalia)
   "File-like object to provide @command{/bin/noctalia}.")
  (environment-variables
   (list-of-strings '())
   "Environment variables to pass to noctalia, as a list of
@code{NAME=VALUE} strings."))

(define (home-noctalia-shepherd-service config)
  (match-record config <home-noctalia-configuration>
      (noctalia environment-variables)
    (list (shepherd-service
            (documentation "Start noctalia.")
            (provision '(noctalia))
            (requirement '(dbus graphical-session))
            (modules '((shepherd support)))
            (start
             #~(lambda args
                 ((make-forkexec-constructor
                   (list #$(file-append noctalia "/bin/noctalia"))
                   #:log-file (in-vicinity %user-log-dir "noctalia.log")
                   ;; Inherit graphical session environment plus extras.
                   #:environment-variables
                   (append (list #$@environment-variables) (environ)))
                  args)))
            (stop #~(make-kill-destructor))))))

(define home-noctalia-service-type
  (service-type
    (inherit rosenthal:home-noctalia-service-type)
    (extensions
     (list (service-extension home-profile-service-type
                              (compose list home-noctalia-configuration-noctalia))
           (service-extension home-shepherd-service-type
                              home-noctalia-shepherd-service)
           (service-extension rosenthal:home-graphical-session-service-type
                              (const 'wayland))))
    ;; The inherited default value is an instance of the upstream
    ;; configuration record type; replace it with ours.
    (default-value (home-noctalia-configuration))))
