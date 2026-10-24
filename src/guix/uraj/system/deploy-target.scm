;;; Select the OS or its embedded Home for deployment.
(define-module (uraj system deploy-target)
  #:use-module (gnu home)
  #:use-module (gnu services)
  #:use-module (gnu system)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module (uraj system home)
  #:export (deploy-target))

(define (embedded-homes os)
  (filter-map
   (lambda (entry)
     (match entry
       ((_ (? home-environment? home)) home)
       (_ #f)))
   (service-value
    (fold-services (operating-system-services os)
                   #:target-type guix-home-with-environment-service-type))))

(define (single-home os)
  ;; Do not silently deploy another account's Home on multi-user systems.
  (match (embedded-homes os)
    ((home) home)
    (_ (error "Home target requires exactly one embedded Home"))))

(define (deploy-target os)
  (let ((target (getenv "URAJ_DEPLOY_TARGET")))
    (cond
     ((or (not target) (string=? target "system")) os)
     ((string=? target "home")
      (when (getenv "TO_ISO")
        (error "Home deployment cannot be combined with TO_ISO"))
      (single-home os))
     (else (error "Unknown URAJ_DEPLOY_TARGET" target)))))
