;;; guix time-machine -C env/guix/channels-lock.scm -- repl test/guix/uraj/services/immich.scm
(use-modules (gnu) (gnu services) (gnu services shepherd)
             (gnu image) (gnu system image)
             (guix gexp) (json) (srfi srfi-1) (srfi srfi-64)
             (uraj services immich) (uraj services paseo-relay))

(define (services os)
  (shepherd-configuration-services
   (service-value (fold-services (operating-system-services os)
                                #:target-type shepherd-root-service-type))))
(define (lookup all name)
  (find (lambda (s) (memq name (shepherd-service-provision s))) all))
(define (ancestors all name)
  (let walk ((pending (list name)) (seen '()))
    (if (null? pending) seen
        (let ((name (car pending)))
          (if (memq name seen) (walk (cdr pending) seen)
              (let ((s (lookup all name)))
                (unless s (error "Missing dependency" name))
                (walk (append (shepherd-service-requirement s) (cdr pending))
                      (cons name seen))))))))
(define (load-storie)
  (load (string-append (getcwd) "/env/guix/os/storie.scm")))
(unsetenv "TO_ISO")
(define installed (services (load-storie)))
(setenv "TO_ISO" "1")
(define live (services (operating-system-for-image
                        (os->image (load-storie)
                                   #:type (lookup-image-type-by-name 'iso9660)))))
(unsetenv "TO_ISO")

(test-begin "immich")
(test-assert "complete headless Docker dependency graph"
  (ancestors installed 'dockerd))
(test-assert "Immich waits for storage and Docker"
  (every (lambda (r) (memq r (ancestors installed 'immich)))
         '(dockerd zfs-data-ready file-system-/data)))
(test-assert "Immich waits for SOPS password decryption"
  (every (lambda (r) (memq r (ancestors installed 'immich)))
         '(sops-secrets sops-secret-immich/db-password sops-secrets-host-key)))
(test-assert "applications wait for the shared network"
  (and (memq 'docker-lan (ancestors installed 'immich))
       (memq 'docker-lan (ancestors installed 'paseo-relay))))
(test-assert "relay is independent of Immich, secrets and data pools"
  (not (any (lambda (r) (memq r '(immich zfs-data-ready sops-secrets)))
            (ancestors installed 'paseo-relay))))
(for-each
 (lambda (name)
   (test-assert (format #f "~a remains independent of Immich and data pools" name)
     (not (any (lambda (r) (memq r '(immich zfs-data-ready zfs-mount)))
               (ancestors installed name)))))
 '(networking ssh-daemon term-tty1 dockerd))
(for-each (lambda (name)
            (test-assert (format #f "installer does not run ~a" name)
              (not (lookup live name))))
          '(immich dockerd containerd docker-lan paseo-relay))
(define shared-manifest
  (json-string->scm
   (plain-file-content
    (immich-compose-file (immich-configuration (external-network "docker_lan"))))))
(define relay-manifest
  (json-string->scm
   (plain-file-content (paseo-relay-compose-file (paseo-relay-configuration)))))
(define (lan manifest) (assoc-ref (assoc-ref manifest "networks") "lan"))
(test-equal "Immich and relay use the same externally managed network"
  (lan shared-manifest) (lan relay-manifest))
(test-equal "Compose must not delete the shared network" #t
  (assoc-ref (lan shared-manifest) "external"))
(define relay (assoc-ref (assoc-ref relay-manifest "services") "relay"))
(test-equal "relay uses .8, leaving .6 for Immich and .7 for daemon" "172.31.0.8"
  (assoc-ref (assoc-ref (assoc-ref relay "networks") "lan") "ipv4_address"))
(test-equal "build works without Docker's default bridge" "host"
  (assoc-ref (assoc-ref relay "build") "network"))
(define manifest
  (json-string->scm (plain-file-content (immich-compose-file (immich-configuration)))))
(define containers (assoc-ref manifest "services"))
(test-equal "single macvlan address" "172.31.0.6"
  (assoc-ref (assoc-ref (assoc-ref (assoc-ref containers "network") "networks") "lan") "ipv4_address"))
(for-each
 (lambda (entry)
   (test-equal "no Docker reboot auto-start bypass" "on-failure"
     (assoc-ref (cdr entry) "restart"))
   (test-assert "no host published ports" (not (assoc-ref (cdr entry) "ports"))))
 containers)
(for-each (lambda (name)
            (test-equal "application containers share anchor namespace" "service:network"
              (assoc-ref (assoc-ref containers name) "network_mode")))
          '("database" "redis" "immich-machine-learning" "immich-server"))
(test-assert "password contents are not in the manifest"
  (not (assoc-ref (assoc-ref (assoc-ref containers "database") "environment") "POSTGRES_PASSWORD")))

;; Execute the real preparation body with fake filesystem operations.  This
;; proves guards run before writes, without needing root or touching storage.
(define* (prepare mounts present #:optional (config (immich-configuration)))
  (let ((m (make-fresh-user-module)) (writes '()) (generated #f))
    (for-each (lambda (interface) (module-use! m (resolve-interface interface)))
              '((srfi srfi-1) (ice-9 format) (rnrs io ports) (rnrs bytevectors)))
    (define (define! name value) (module-define! m name value))
    (define! 'mounts (lambda () mounts))
    (define! 'mount-point car)
    (define! 'mount-type cadr)
    (define! 'mount-source caddr)
    (define! 'file-exists? (lambda (p) (member p present)))
    (define! 'umask (lambda _ #t))
    (define! 'mkdir-p (lambda (p) (set! writes (cons p writes))))
    (define! 'chmod (lambda _ #t))
    (define! 'stat (lambda _ 65))
    (define! 'stat:size identity)
    (define! 'copy-file (lambda _ #t))
    (define! 'rename-file (lambda _ #t))
    (define! 'call-with-output-file
      (lambda (path proc)
        (set! generated (call-with-output-string proc))))
    (let* ((body (gexp->approximate-sexp
                  (program-file-gexp (immich-prepare-program config))))
           (ok? (catch #t
                  (lambda () (eval `(begin ,@(cddr body)) m) #t)
                  (lambda _ #f))))
      (list ok? (reverse writes) generated))))
(define mounted '(("/data" "btrfs" "/dev/nvme0n1p3")
                  ("/core-data/archive" "zfs" "core-data/archive")))
(define nic "/sys/class/net/enp1s0")
(test-equal "missing ZFS never creates directories" '(#f () #f)
  (prepare (take mounted 1) (list nic)))
(test-equal "wrong dataset never creates directories" '(#f () #f)
  (prepare '(("/data" "btrfs" "nvme") ("/core-data/archive" "zfs" "wrong")) (list nic)))
(test-equal "missing NVMe never creates directories" '(#f () #f)
  (prepare (drop mounted 1) (list nic)))
(test-equal "missing NIC never creates directories" '(#f () #f)
  (prepare mounted '()))
(let ((result (prepare mounted (list nic "/data/immich/db-password"))))
  (test-assert "existing password reused" (and (car result) (not (caddr result)))))
(let ((result (prepare mounted (list nic))))
  (test-assert "fresh password generated successfully" (car result))
  (test-equal "256-bit hex password plus newline" 65 (string-length (or (caddr result) ""))))
(test-assert "existing database without password refuses replacement"
  (not (car (prepare mounted (list nic "/data/immich/postgres/PG_VERSION")))))
(test-assert "missing SOPS secret never generates a replacement"
  (not (car (prepare mounted (list nic)
                       (immich-configuration (database-password-file "/run/secrets/immich"))))))
(define failures (test-runner-fail-count (test-runner-current)))
(test-end "immich")
(exit (if (zero? failures) 0 1))
