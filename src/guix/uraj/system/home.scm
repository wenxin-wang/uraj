(define-module (uraj system home)
  #:use-module (gnu services)
  #:use-module (gnu services guix)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (ice-9 match)
  #:export (guix-home-with-environment-service-type))

;; setup-environment requires HOME_ENVIRONMENT, but upstream's system
;; service does not pass it to activate.  Wrap only the Shepherd extension,
;; retaining upstream's service dependencies, user switching and lifecycle.
;; Remove this workaround when upstream initializes the variable itself.
(define (home-with-activation-environment home)
  (file-union
   "home-with-activation-environment"
   `(("activate"
      ,(program-file
        "activate-home-with-environment"
        #~(begin
            ;; Use the new generation, not the possibly stale ~/.guix-home.
            (setenv "HOME_ENVIRONMENT" #$home)
            (execl #$(file-append home "/activate")
                   #$(file-append home "/activate"))))))))

(define guix-home-with-environment-service-type
  (service-type
   (inherit guix-home-service-type)
   (extensions
    (map (lambda (extension)
           (if (eq? (service-extension-target extension)
                    shepherd-root-service-type)
               (service-extension
                shepherd-root-service-type
                (lambda (config)
                  ((service-extension-compute extension)
                   (map (match-lambda
                          ((user home)
                           (list user (home-with-activation-environment home))))
                        config))))
               extension))
         (service-type-extensions guix-home-service-type)))))
