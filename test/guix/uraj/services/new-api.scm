;;; guix time-machine -C env/guix/channels-lock.scm -- repl test/guix/uraj/services/new-api.scm
(use-modules (gnu) (gnu services) (gnu services shepherd)
             (gnu image) (gnu system image)
             (guix gexp) (json) (srfi srfi-1) (srfi srfi-64)
             (uraj services new-api) (uraj services paseo-relay))

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

(test-begin "new-api")
(test-assert "new-api waits for Docker, the shared network and storage"
  (every (lambda (r) (memq r (ancestors installed 'new-api)))
         '(dockerd docker-lan zfs-data-ready file-system-/data)))
(test-assert "new-api is independent of Immich and SOPS"
  (not (any (lambda (r) (memq r '(immich sops-secrets)))
            (ancestors installed 'new-api))))
(test-assert "installer does not run new-api" (not (lookup live 'new-api)))

(define config (new-api-configuration (image "localhost/new-api-traj:test")))
(define manifest
  (json-string->scm (plain-file-content (new-api-compose-file config))))
(define relay-manifest
  (json-string->scm
   (plain-file-content (paseo-relay-compose-file (paseo-relay-configuration)))))
(define (lan manifest) (assoc-ref (assoc-ref manifest "networks") "lan"))
(define containers (assoc-ref manifest "services"))
(define (container name) (assoc-ref containers name))

(test-equal "new-api joins the relay's externally managed network"
  (lan relay-manifest) (lan manifest))
(test-equal "new-api uses .9, after Immich .6, daemon .7 and relay .8" "172.31.0.9"
  (assoc-ref (assoc-ref (assoc-ref (container "network") "networks") "lan") "ipv4_address"))
(test-equal "configured image is used as is" "localhost/new-api-traj:test"
  (assoc-ref (container "new-api") "image"))
(for-each
 (lambda (entry)
   (test-equal "no Docker reboot auto-start bypass" "on-failure"
     (assoc-ref (cdr entry) "restart"))
   (test-assert "no host published ports" (not (assoc-ref (cdr entry) "ports"))))
 containers)
(for-each (lambda (name)
            (test-equal "containers share the anchor namespace" "service:network"
              (assoc-ref (container name) "network_mode")))
          '("new-api" "database" "redis"))
(let ((env (assoc-ref (container "new-api") "environment"))
      (entrypoint (vector->list (assoc-ref (container "new-api") "entrypoint"))))
  (test-assert "credentials are not in the manifest"
    (not (any (lambda (k) (assoc-ref env k)) '("SQL_DSN" "SESSION_SECRET"))))
  (test-assert "entrypoint escapes $ from Compose interpolation"
    (and (string-contains (last entrypoint) "$$(cat /run/secrets/db-password)")
         (not (string-contains (string-delete #\$ (last entrypoint)) "$")))))
(test-assert "database password is not in the manifest"
  (not (assoc-ref (assoc-ref (container "database") "environment") "POSTGRES_PASSWORD")))

;; Execute the real preparation body with fake filesystem operations, as in
;; the Immich test: guards must run before any directory is created.
(define (prepare mounts present)
  (let ((m (make-fresh-user-module)) (writes '()) (generated '()))
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
    (define! 'stat (lambda _ 64))
    (define! 'stat:size identity)
    (define! 'copy-file (lambda _ #t))
    (define! 'rename-file (lambda _ #t))
    (define! 'call-with-output-file
      (lambda (path proc)
        (set! generated (cons (call-with-output-string proc) generated))))
    (let* ((body (gexp->approximate-sexp
                  (program-file-gexp (new-api-prepare-program config))))
           (ok? (catch #t
                  (lambda () (eval `(begin ,@(cddr body)) m) #t)
                  (lambda _ #f))))
      (list ok? (reverse writes) generated))))
(define mounted '(("/data" "btrfs" "/dev/nvme0n1p3")
                  ("/media-data" "zfs" "media-data")))
(test-equal "missing ZFS never creates directories" '(#f () ())
  (prepare (take mounted 1) '()))
(test-equal "wrong dataset never creates directories" '(#f () ())
  (prepare '(("/data" "btrfs" "nvme") ("/media-data" "zfs" "wrong")) '()))
(test-equal "missing NVMe never creates directories" '(#f () ())
  (prepare (drop mounted 1) '()))
(let ((result (prepare mounted '())))
  (test-assert "fresh secrets generated" (car result))
  (test-equal "two 256-bit hex secrets" '(64 64) (map string-length (caddr result))))
(let ((result (prepare mounted '("/data/new-api/secrets/db-password"
                                 "/data/new-api/secrets/session-secret"))))
  (test-assert "existing secrets reused" (and (car result) (null? (caddr result)))))
(test-assert "existing database without password refuses replacement"
  (not (car (prepare mounted '("/data/new-api/postgres/PG_VERSION")))))
(define failures (test-runner-fail-count (test-runner-current)))
(test-end "new-api")
(exit (if (zero? failures) 0 1))
