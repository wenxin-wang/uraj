;;; Select the OS, its embedded Home, or a Paseo-only trial bundle.
(define-module (uraj system paseo-trial)
  #:use-module (gnu home)
  #:use-module (gnu home services shepherd)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (gnu system)
  #:use-module (guix gexp)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module (uraj system home)
  #:export (paseo-trial-target))

(define (paseo-services services)
  (filter (lambda (service)
            (any (lambda (name)
                   (memq name (shepherd-service-provision service)))
                 '(paseo paseo-broker)))
          services))

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

(define (trial-bundle os)
  (let* ((services (operating-system-services os))
         (system-services
          (paseo-services
           (shepherd-configuration-services
            (service-value
             (fold-services services
                            #:target-type shepherd-root-service-type)))))
         (user-services
          (append-map
           (lambda (home)
             (paseo-services
              (home-shepherd-configuration-services
               (service-value
                (fold-services (home-environment-services home)
                               #:target-type home-shepherd-service-type)))))
           (embedded-homes os)))
         (selected (append system-services user-services)))
    ;; Never guess which Shepherd owns a service, or export a partial stack.
    (unless (and (= (length selected) 2)
                 (= (count (lambda (service)
                             (memq 'paseo (shepherd-service-provision service)))
                           selected)
                    1)
                 (= (count (lambda (service)
                             (memq 'paseo-broker
                                   (shepherd-service-provision service)))
                           selected)
                    1)
                 (or (null? system-services) (null? user-services)))
      (error "Paseo trial requires one complete stack in one Shepherd"))
    (file-union
     "paseo-trial"
     `(("owner" ,(plain-file "owner" (if (null? system-services)
                                           "user\n" "system\n")))
       ,@(map
          (lambda (service)
            (let* ((name (if (memq 'paseo (shepherd-service-provision service))
                             "paseo" "paseo-broker"))
                   (definition (shepherd-service-file service)))
              (list (string-append name ".scm")
                    (scheme-file
                     (string-append name "-trial.scm")
                     #~(begin
                         (use-modules (shepherd service))
                         (register-services
                          (list (primitive-load #$definition))))))))
          selected)))))

(define (paseo-trial-target os)
  (let ((target (getenv "URAJ_DEPLOY_TARGET")))
    (cond
     ((or (not target) (string=? target "system")) os)
     ((member target '("home" "paseo"))
      (when (getenv "TO_ISO")
        (error "Partial deployment cannot be combined with TO_ISO"))
      (if (string=? target "home")
          (single-home os)
          (trial-bundle os)))
     (else (error "Unknown URAJ_DEPLOY_TARGET" target)))))
