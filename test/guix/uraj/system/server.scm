;; Run with the pinned channels and -L src/guix -L src/guile.
(use-modules (gnu) (gnu services) (gnu services desktop) (gnu system pam)
             (guix gexp)
             (srfi srfi-1) (srfi srfi-64)
             (uraj system base)
             (uraj system server))

(test-begin "server-login-sessions")
(define os
  (operating-system
    (inherit (server-base-os (main-user-account "target")
                             (plain-file "keys.pub" "")))
    (file-systems (cons (file-system
                          (device "none") (mount-point "/") (type "tmpfs"))
                        %base-file-systems))))
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

;; Guix Home's on-first-login needs /run/user/$UID on SSH logins too, not
;; only on greetd's console.
(for-each
 (lambda (name)
   (let ((pam (find (lambda (p) (string=? name (pam-service-name p))) pams)))
     (test-assert (string-append name " exists") pam)
     (test-assert (string-append name " has pam_elogind")
       (any (lambda (entry) (string-contains (module-name entry) "pam_elogind.so"))
            (pam-service-session pam)))
     (test-assert (string-append name " has no competing pam_mount")
       (not (any (lambda (entry) (string-contains (module-name entry) "pam_mount.so"))
                 (append (pam-service-auth pam) (pam-service-session pam)))))))
 '("sshd" "greetd" "login" "su"))

(define failures (test-runner-fail-count (test-runner-current)))
(test-end "server-login-sessions")
(exit (if (zero? failures) 0 1))
