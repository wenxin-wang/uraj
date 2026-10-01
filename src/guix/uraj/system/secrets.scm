;;; Per-machine SOPS identities derived from the target's SSH host key.
(define-module (uraj system secrets)
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu packages golang-crypto)
  #:use-module (gnu packages password-utils)
  #:use-module (guix gexp)
  #:use-module (sops services sops)
  #:export (%host-sops-age-key-file host-sops-services))

(define %host-sops-age-key-file "/var/lib/sops/age/keys.txt")

(define* (host-sops-services #:optional (secrets '()))
  "Derive a SOPS age identity from this machine's Ed25519 SSH host key.
OpenSSH creates missing host keys during activation, before Shepherd starts
the sops-secrets-host-key service.  No target private key is read at build time."
  (list
   ;; Protect the directory before upstream age-store opens the identity
   ;; file; upstream sets the resulting file's permissions to 0400.
   (simple-service 'host-sops-private-state activation-service-type
     #~(begin
         (for-each
          (lambda (directory)
            (unless (file-exists? directory)
              (mkdir directory #o700))
            (unless (eq? 'directory (stat:type (lstat directory)))
              (error "SOPS state path must be a directory" directory))
            (chown directory 0 0)
            (chmod directory #o700))
          '("/var/lib/sops" "/var/lib/sops/age"))))
   ;; Make public-key extraction available without entering a Guix shell.
   (simple-service 'host-sops-tools profile-service-type (list age ssh-to-age))
   (service sops-secrets-service-type
     (sops-service-configuration
       (generate-key? #t)
       (host-ssh-key "/etc/ssh/ssh_host_ed25519_key")
       (age-key-file %host-sops-age-key-file)
       (secrets secrets)))))
