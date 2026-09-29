;;; Run with the project's pinned Guix modules:
;;; guix time-machine -C env/guix/channels-lock.scm -- repl test/guix/uraj/system/iso.scm
(use-modules (gnu)
             (gnu image)
             (gnu services)
             (gnu services avahi)
             (gnu services base)
             (gnu services shepherd)
             (gnu system image)
             (guix gexp)
             (srfi srfi-1)
             (srfi srfi-64))

(define (services-of-kind os kind)
  (filter (lambda (s) (eq? (service-kind s) kind))
          (operating-system-user-services os)))

(define (guix-config os)
  (service-value (car (services-of-kind os guix-service-type))))

(test-begin "iso-build-host-substitutes")
(for-each
 (lambda (file)
   (unsetenv "TO_ISO")
   (let* ((installed (load file))
          (installed-keys (guix-configuration-authorized-keys
                           (guix-config installed))))
     (let ((without-key
            (service-value
             (find (lambda (s) (eq? (service-kind s) guix-service-type))
                   ((@@ (uraj system iso) iso-services)
                    installed "/dev/null/missing-signing-key.pub")))))
       (test-equal "missing host key preserves existing trust"
         installed-keys (guix-configuration-authorized-keys without-key))
       (test-assert "missing host key still enables discovery"
         ((@@ (gnu services base) guix-configuration-discover?) without-key)))
     (setenv "TO_ISO" "1")
     (let* ((live (load file))
            (live-keys (guix-configuration-authorized-keys (guix-config live)))
            (host-key (car live-keys)))
       (test-equal "ISO adds the build host key only when present"
         (+ (if (file-exists? "/etc/guix/signing-key.pub") 1 0)
            (length installed-keys))
         (length live-keys))
       (test-equal "ISO includes an existing build host public key"
         (file-exists? "/etc/guix/signing-key.pub")
         (and (local-file? host-key)
              (string=? (local-file-file host-key)
                        "/etc/guix/signing-key.pub")))
       (test-assert "ISO enables discovery"
         ((@@ (gnu services base) guix-configuration-discover?)
          (guix-config live)))
       (test-assert "installed system has no build host key"
         (not (any (lambda (key)
                     (and (local-file? key)
                          (string=? (local-file-file key)
                                    "/etc/guix/signing-key.pub")))
                   installed-keys)))
       (for-each
        (lambda (os)
          (test-equal "exactly one Avahi service" 1
            (length (services-of-kind os avahi-service-type)))
          (test-equal "exactly one publish service" 1
            (length (services-of-kind os guix-publish-service-type)))
          ;; Fold the actual service graph: catches missing D-Bus extensions
          ;; on the headless role as well as duplicate desktop services.
          (let ((services
                 (shepherd-configuration-services
                  (service-value
                   (fold-services (operating-system-services os)
                                  #:target-type shepherd-root-service-type)))))
            (test-assert "publish waits for Avahi"
              (memq 'avahi-daemon
                    (shepherd-service-requirement
                     (find (lambda (s)
                             (memq 'guix-publish (shepherd-service-provision s)))
                           services))))))
        (list installed
              (operating-system-for-image
               (os->image live
                          #:type (lookup-image-type-by-name 'iso9660))))))))
 (map (lambda (name)
        (string-append (getcwd) "/env/guix/os/" name ".scm"))
      '("lappie" "storie")))
(unsetenv "TO_ISO")
(define failures (test-runner-fail-count (test-runner-current)))
(test-end "iso-build-host-substitutes")
(exit (if (zero? failures) 0 1))
