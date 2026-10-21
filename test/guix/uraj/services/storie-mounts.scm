;;; Run with the repository's locked Guix and -L src/guix -L src/guile.
(use-modules (gnu) (gnu image) (gnu system image)
             (gnu services) (gnu services shepherd)
             (srfi srfi-1) (srfi srfi-64))

(define (load-host host live?)
  (if live? (setenv "TO_ISO" "1") (unsetenv "TO_ISO"))
  (let ((os (primitive-load
             (string-append (getcwd) "/env/guix/os/" host ".scm"))))
    (if live?
        (operating-system-for-image
         (os->image os #:type (lookup-image-type-by-name 'iso9660)))
        os)))

(define (services os)
  (shepherd-configuration-services
   (service-value (fold-services (operating-system-services os)
                                #:target-type shepherd-root-service-type))))

(test-begin "storie-mounts")
(for-each
 (lambda (host)
   (let* ((os (load-host host #f))
          (all (services os))
          (automount
           (find (lambda (s) (memq 'autofs (shepherd-service-provision s))) all)))
     (test-assert (string-append host " starts the local automounter")
       (and automount (shepherd-service-auto-start? automount)))
     (test-assert "automounter has no remote mount or rpc.statd prerequisite"
       (and automount (null? (shepherd-service-requirement automount))))
     (test-assert "no eager NFS mounts in the host filesystem list"
       (not (any (lambda (fs) (member (file-system-type fs) '("nfs" "nfs4")))
                 (operating-system-file-systems os))))
     (test-assert "every Shepherd dependency has a provider"
       (every (lambda (s)
                (every (lambda (name)
                         (any (lambda (provider)
                                (memq name (shepherd-service-provision provider)))
                              all))
                       (shepherd-service-requirement s)))
              all)))
   (test-assert (string-append host " installer omits NAS automounts")
     (not (any (lambda (s) (memq 'autofs (shepherd-service-provision s)))
               (services (load-host host #t))))))
 '("lappie" "hypie"))
(unsetenv "TO_ISO")
(define failures (test-runner-fail-count (test-runner-current)))
(test-end "storie-mounts")
(exit (if (zero? failures) 0 1))
