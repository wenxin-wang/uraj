;;; Run from the repository root with the lock-pinned Guix repl.
(use-modules (gnu)
             (gnu services)
             (gnu services shepherd)
             (gnu services ssh)
             (sops services sops)
             (srfi srfi-1)
             (srfi srfi-64)
             (uraj system secrets))

(define (of-kind os kind)
  (filter (lambda (s) (eq? (service-kind s) kind))
          (operating-system-user-services os)))

(test-begin "machine-sops-identities")
(for-each
 (lambda (host)
   (let ((file (string-append (getcwd) "/env/guix/os/" host ".scm")))
     (unsetenv "TO_ISO")
     (let* ((os (load file))
            (configs (of-kind os sops-secrets-service-type))
            (config (service-value (car configs)))
            (ssh (service-value (car (of-kind os openssh-service-type))))
            (services
             (shepherd-configuration-services
              (service-value
               (fold-services (operating-system-services os)
                              #:target-type shepherd-root-service-type))))
            (key-service
             (find (lambda (s)
                     (memq 'sops-secrets-host-key
                           (shepherd-service-provision s)))
                   services)))
       (test-equal "one SOPS service per installed host" 1 (length configs))
       (test-assert "OpenSSH generates missing host keys during activation"
         (openssh-configuration-generate-host-keys? ssh))
       (test-assert "SOPS derives a machine identity"
         (sops-service-configuration-generate-key? config))
       (test-equal "derive from Ed25519, not RSA"
         "/etc/ssh/ssh_host_ed25519_key"
         (sops-service-configuration-host-ssh-key config))
       (test-equal "persistent identity path"
         "/var/lib/sops/age/keys.txt"
         (sops-service-configuration-age-key-file config))
       (test-equal "no secrets before recipient enrollment" '()
         (sops-service-configuration-secrets config))
       (test-assert "key generation waits until after system activation"
         (memq 'user-processes (shepherd-service-requirement key-service)))
       (test-assert "key generation starts automatically"
         (shepherd-service-auto-start? key-service)))
     (setenv "TO_ISO" "1")
     (let ((live (load file)))
       (test-equal "live installer does not derive SOPS identities" '()
         (of-kind live sops-secrets-service-type))
       (test-assert "live installer has no SOPS private-state activation"
         (not (any (lambda (s)
                     (eq? 'host-sops-private-state
                          (service-type-name (service-kind s))))
                   (operating-system-user-services live)))))))
 '("lappie" "storie"))
(unsetenv "TO_ISO")
(define failures (test-runner-fail-count (test-runner-current)))
(test-end "machine-sops-identities")
(exit (if (zero? failures) 0 1))
