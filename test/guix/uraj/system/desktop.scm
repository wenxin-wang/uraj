;; Run with the pinned channels and -L src/guix -L src/guile.
(use-modules (gnu) (gnu services) (gnu services base)
             (gnu services desktop) (gnu system pam) (guix gexp)
             (srfi srfi-1) (srfi srfi-13) (srfi srfi-64)
             (uraj system desktop))

(test-begin "desktop-session-lifecycle")
(define os (load (string-append (getcwd) "/env/guix/os/lappie.scm")))
(define config
  (service-value
   (fold-services (operating-system-services os)
                  #:target-type pam-root-service-type)))
(define transform
  (apply compose identity
         ((@@ (gnu system pam) pam-configuration-transformers) config)))
(define pams
  (map transform ((@@ (gnu system pam) pam-configuration-services) config)))
(define (module-name entry)
  (let ((module (pam-entry-module entry)))
    (if (file-append? module)
        (string-concatenate (file-append-suffix module))
        module)))

;; Fold the complete graph so elogind's later PAM extension participates.
(for-each
 (lambda (name)
   (let ((pam (find (lambda (p) (string=? name (pam-service-name p))) pams)))
     (test-assert (string-append name " exists") pam)
     (test-assert (string-append name " retains pam_elogind")
       (any (lambda (entry) (string-contains (module-name entry) "pam_elogind.so"))
            (pam-service-session pam)))
     (test-assert (string-append name " has no competing pam_mount")
       (not (any (lambda (entry) (string-contains (module-name entry) "pam_mount.so"))
                 (append (pam-service-auth pam) (pam-service-session pam)))))))
 '("greetd" "login" "su"))
(test-assert "elogind is retained"
  (find (lambda (s) (eq? (service-kind s) elogind-service-type))
        (operating-system-services os)))

(define failures (test-runner-fail-count (test-runner-current)))
(test-end "desktop-session-lifecycle")
(exit (if (zero? failures) 0 1))
