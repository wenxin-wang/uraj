(define-module (uraj system home)
  #:use-module (gnu services)
  #:use-module (gnu services guix)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:export (guix-home-with-environment-service-type
            home-activation-dependency))

;; setup-environment requires HOME_ENVIRONMENT, but upstream's system
;; service does not pass it to activate. Keep upstream user switching and
;; lifecycle, adding explicit per-user dependencies (for decrypted settings).
;; Remove the environment wrapper once upstream initializes the variable.
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

(define-record-type <home-activation-dependency>
  (home-activation-dependency user requirements)
  home-activation-dependency?
  (user home-dependency-user)
  (requirements home-dependency-requirements))

(define (add-home-dependencies services dependencies)
  (map
   (lambda (service)
     (shepherd-service
      (inherit service)
      (requirement
       (delete-duplicates
        (append
         (shepherd-service-requirement service)
         (append-map
          (lambda (dependency)
            (if (memq (string->symbol
                       (string-append "guix-home-" (home-dependency-user dependency)))
                      (shepherd-service-provision service))
                (home-dependency-requirements dependency)
                '()))
          dependencies))))))
   services))

(define guix-home-with-environment-service-type
  (service-type
   (inherit guix-home-service-type)
   (extensions
    (map
     (lambda (extension)
       (service-extension
        (service-extension-target extension)
        (lambda (config)
          (let ((homes (remove home-activation-dependency? config))
                (dependencies (filter home-activation-dependency? config)))
            (if (eq? (service-extension-target extension)
                     shepherd-root-service-type)
                (add-home-dependencies
                 ((service-extension-compute extension)
                  (map (match-lambda
                         ((user home)
                          (list user (home-with-activation-environment home))))
                       homes))
                 dependencies)
                ((service-extension-compute extension) homes))))))
     (service-type-extensions guix-home-service-type)))))
