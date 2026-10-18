;;; One controller per Android device, including while configuring the WebUI.
(define-module (uraj services mower)
  #:use-module (gnu services)
  #:use-module (gnu services containers)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:use-module (uraj packages mower)
  #:use-module (uraj services logs)
  #:use-module (uraj utils gexp)
  #:export (mower-configuration mower-service-type mower-container))

(define-record-type* <mower-configuration>
  mower-configuration make-mower-configuration mower-configuration?
  (data-directory mower-data-directory (default "/var/lib/mower"))
  (controller-lock mower-controller-lock (default "/var/lib/maa/daily.lock"))
  (auto-start? mower-auto-start? (default #f)))

(define (mower-container config)
  (oci-container-configuration
    (provision "mower")
    (image %mower-image-tag)
    (network "redroid")
    (requirement '(restricted-network redroid-maa mower-ready mower-image))
    (auto-start? (mower-auto-start? config))
    (respawn? #t)
    (log-file "/var/log/mower/mower.log")
    ;; No published ports, Docker socket, GPU, or privileged mode.
    (extra-arguments
     (list "--ip" "10.203.0.3" "--dns" "114.114.114.114"
           "--cap-drop=ALL" "--security-opt=no-new-privileges"
           "--stop-timeout" "30"
           "--mount" (string-append "type=bind,source=" (mower-data-directory config)
                                    ",target=/mower-data")
           "--mount" (string-append "type=bind,source=" (mower-controller-lock config)
                                    ",target=/run/maa-controller.lock")))))

(define mower-service-type
  (service-type
    (name 'mower)
    (extensions
     (list
      (service-extension oci-service-type
        (lambda (config)
          (oci-extension (containers (list (mower-container config))))))
      (service-extension service-log-service-type
        (lambda (_) (list (service-log (name "mower")))))
      (service-extension shepherd-root-service-type
        (lambda (config)
          (list
           (shepherd-service
             (provision '(mower-ready))
             (requirement '(user-processes))
             (auto-start? (mower-auto-start? config))
             (documentation "Prepare Mower state and the shared MAA device lock.")
             (start
              (with-uraj-modules '((uraj build mower))
                #~(lambda _
                    (invoke
                     #$(program-file "mower-prepare"
                         (with-uraj-modules '((uraj build mower))
                           #~(begin
                               (use-modules (uraj build mower))
                               (prepare-mower #$(mower-data-directory config)
                                              #$(mower-controller-lock config))))))
                    #t)))
             (stop #~(lambda _ #f)))
           (shepherd-service
             (provision '(mower-image))
             (requirement '(dockerd user-processes))
             (auto-start? (mower-auto-start? config))
             (one-shot? #t)
             (documentation "Build the pinned headless Mower image when its context changes.")
             (start #~(lambda _ (invoke #$%mower-build-image) #t))))))))
    (default-value (mower-configuration))
    (description "Headless Mower on hypie's private redroid network; requires the maa account.")))
