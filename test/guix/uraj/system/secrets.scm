;;; Run from the repository root with the lock-pinned Guix repl.
(use-modules (gnu)
             (gnu services)
             (gnu services shepherd)
             (gnu services ssh)
             (sops services sops)
             (sops secrets)
             (srfi srfi-1)
             (srfi srfi-64)
             (uraj common agent-secrets)
             (uraj system secrets)
             (uraj utils file path))

(define (of-kind os kind)
  (filter (lambda (s) (eq? (service-kind s) kind))
          (operating-system-user-services os)))

(define (key<? a b)
  (string<? (string-join a "/") (string-join b "/")))

(define (expected-secrets host)
  "HOST's own secrets, then those of its agents: the GitHub tiers once
scripts/secrets/github_token.py has written them, and the sandbox policies
whose files exist."
  (sort
   (append
    (assoc-ref '(("lappie" ("strongswan" "fwd2home"))
                 ("hypie" ("strongswan" "fwd2home"))
                 ("storie" ("immich" "db-password")))
               host)
    (if (file-exists? (project-path "secrets/shared/github.yaml"))
        (map (lambda (tier) (list "github" tier))
             '("public" "personal" "world"))
        '())
    (filter-map (lambda (policy)
                  (and (member host (sandbox-policy-hosts (first policy)))
                       (third policy)))
                %sandbox-policies)
    (filter-map (lambda (entry)
                  (and (member host (agent-configuration-hosts (first entry)))
                       (third entry)))
                %agent-configurations))
   key<?))

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
       (test-equal "only the host's declared secrets"
         (expected-secrets host)
         (sort (map sops-secret-key
                    (sops-service-configuration-secrets config))
               key<?))
       (test-assert "agent secrets belong to the main user alone"
         (every (lambda (secret)
                  (or (not (member (first (sops-secret-key secret))
                                   '("github" "contained-agent" "paseo")))
                      (and (string=? "wenxin" (sops-secret-user secret))
                           (= #o400 (sops-secret-permissions secret)))))
                (sops-service-configuration-secrets config)))
       (let ((home (find (lambda (service)
                           (memq 'guix-home-wenxin
                                 (shepherd-service-provision service)))
                         services)))
         (test-assert "Home activation waits for its decrypted Paseo YAML"
           (and home (memq 'sops-secret-paseo/config.yaml
                            (shepherd-service-requirement home)))))
       (test-assert "key generation waits until after system activation"
         (memq 'user-processes (shepherd-service-requirement key-service)))
       (test-assert "key generation starts automatically"
         (shepherd-service-auto-start? key-service)))
     (setenv "TO_ISO" "1")
     (let ((live (load file)))
       ;; hypie's installer decrypts its VPN secret with the
       ;; administrator's card instead.
       (test-assert "live installer does not derive SOPS identities"
         (not (any (lambda (s)
                     (sops-service-configuration-generate-key?
                      (service-value s)))
                   (of-kind live sops-secrets-service-type))))
       (test-assert "live installer has no SOPS private-state activation"
         (not (any (lambda (s)
                     (eq? 'host-sops-private-state
                          (service-type-name (service-kind s))))
                   (operating-system-user-services live)))))))
 '("lappie" "hypie" "storie"))
(unsetenv "TO_ISO")
(define failures (test-runner-fail-count (test-runner-current)))
(test-end "machine-sops-identities")
(exit (if (zero? failures) 0 1))
