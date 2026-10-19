(define-module (uraj system home)
  #:use-module (gnu services)
  #:use-module (gnu services guix)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (uraj common home-activation)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:export (guix-home-with-environment-service-type
            home-activation-dependency))

;; Wait cooperatively in Shepherd, retaining upstream user switching and
;; the flag that prevents system activation from starting user Shepherd.
(define (synchronous-home-services services homes)
  (map
   (lambda (service home-entry)
     (match home-entry
       ((user home)
        (shepherd-service
         (inherit service)
         (start
          #~(lambda _
              (zero?
               (spawn-command
                (list #$home-activation-program "activate" #$home)
                #:user #$user
                #:group (group:name (getgrgid (passwd:gid (getpw #$user))))
                #:environment-variables
                (list (string-append "HOME=" (passwd:dir (getpw #$user)))
                      "GUIX_SYSTEM_IS_RUNNING_HOME_ACTIVATE=t")))))
         (stop #~(const #f))))))
   services homes))

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
                 (synchronous-home-services
                  ((service-extension-compute extension) homes)
                  homes)
                 dependencies)
                ((service-extension-compute extension) homes))))))
     (service-type-extensions guix-home-service-type)))))
