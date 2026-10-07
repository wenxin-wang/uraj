(use-modules (gnu services) (gnu services shepherd)
             (guix gexp) (sops secrets) (srfi srfi-1) (srfi srfi-64)
             (uraj services strongswan))

(define (secret name)
  (sops-secret (key (list "strongswan" name))
               (file (plain-file "encrypted.yaml" "fixture"))
               (user "root") (group "root") (permissions #o400)))
(define entries (map (lambda (name) (cons name (secret name)))
                     '("fwd2home" "office")))
(define services (service-value (cadr (strongswan-services entries))))
(test-begin "strongswan")
(test-equal "one daemon, two independent connections"
  '((strongswan-charon) (vpn-fwd2home) (vpn-office))
  (map shepherd-service-provision services))
(test-assert "nothing starts on boot"
  (every (lambda (s) (not (shepherd-service-auto-start? s))) services))
(test-assert "no automatic restart"
  (every (lambda (s) (not (shepherd-service-respawn? s))) services))
(test-assert "each connection waits for daemon and decrypted secrets"
  (every (lambda (s) (equal? '(strongswan-charon sops-secrets)
                            (shepherd-service-requirement s))) (cdr services)))
(test-error "duplicate names rejected" #t
  (strongswan-services (list (car entries) (car entries))))
(test-error "unsafe name rejected" #t
  (strongswan-services (list (cons "../escape" (secret "test")))))
(test-error "readable secret rejected" #t
  (strongswan-services
   (list (cons "test" (sops-secret (inherit (secret "test"))
                                   (permissions #o444))))))
;; Evaluate the actual generated handlers with fake I/O. No daemon, keys or
;; network are needed; package paths are irrelevant to these lifecycle checks.
(define calls '())
(define config-text "connections {}")
(define failed-command #f)
(define query-output "")
(define query-status 0)
(define sandbox (make-module))
(module-use! sandbox (resolve-interface '(guile)))
(module-use! sandbox (resolve-interface '(ice-9 textual-ports)))
(module-use! sandbox (resolve-interface '(srfi srfi-13)))
(module-define! sandbox 'OPEN_READ "r")
(module-define! sandbox 'call-with-input-file
  (lambda (path reader) (reader (open-input-string config-text))))
(module-define! sandbox 'file-exists? (const #t))
(module-define! sandbox 'system*
  (lambda (binary . args)
    (set! calls (append calls (list args)))
    (if (equal? (car args) failed-command) 256 0)))
(module-define! sandbox 'open-pipe*
  (lambda args (open-input-string query-output)))
(module-define! sandbox 'close-pipe (lambda (port) (close-port port) query-status))
(define (replace-paths tree)
  (cond ((equal? tree '(*approximate*)) "mock-path")
        ((pair? tree) (cons (replace-paths (car tree)) (replace-paths (cdr tree))))
        (else tree)))
(define (handler accessor)
  (eval (replace-paths (gexp->approximate-sexp (accessor (cadr services)))) sandbox))
(define start (handler shepherd-service-start))
(define stop (handler shepherd-service-stop))
(test-assert "successful initiation marks service running" (start))
(test-equal "start only initiates the selected CHILD"
  '("--initiate" "--child" "fwd2home" "--timeout" "30"
    "--uri" "unix:///run/strongswan-charon.vici")
  (last calls))
(set! calls '())
(set! failed-command "--load-creds")
(test-assert "load failure does not initiate" (not (start)))
(test-equal "stop after first failed load" 1 (length calls))
(set! calls '())
(set! failed-command "--initiate")
(test-assert "failed initiation is not running" (not (start)))
(test-equal "failed initiation cleans up only selected IKE"
  '("--terminate" "--ike" "fwd2home" "--timeout" "10"
    "--uri" "unix:///run/strongswan-charon.vici")
  (last calls))
(set! config-text "secret = REPLACE_WITH_PASSWORD")
(set! calls '())
(test-error "placeholder rejected before loading" #t (start))
(test-equal "placeholder never reaches swanctl" '() calls)
(set! failed-command #f)
(test-assert "successful termination marks stopped" (not (stop)))
(set! failed-command "--terminate")
(test-assert "already disconnected can stop" (not (stop)))
(set! query-output "fwd2home: #1, ESTABLISHED, IKEv2\n")
(test-assert "failed termination preserves running state" (stop))
(set! query-output "")
(set! query-status 256)
(test-assert "query failure is not mistaken for stopped" (stop))
;; Only the named connection starts at boot, and a failed first attempt
;; leaves charon retrying instead of tearing the IKE SA down.
(define boot-services
  (service-value (cadr (strongswan-services entries #:at-boot '("fwd2home")))))
(test-equal "only the boot connection auto-starts"
  '(#f #t #f)
  (map shepherd-service-auto-start? boot-services))
(test-error "unknown boot connection rejected" #t
  (strongswan-services entries #:at-boot '("missing")))
(set! start
  (eval (replace-paths
         (gexp->approximate-sexp (shepherd-service-start (cadr boot-services))))
        sandbox))
(set! config-text "connections {}")
(set! failed-command "--initiate")
(set! calls '())
(test-assert "failed boot initiation stays running" (start))
(test-equal "failed boot initiation is not terminated"
  "--initiate" (car (last calls)))
(define failures (test-runner-fail-count (test-runner-current)))
(test-end "strongswan")
(exit (if (zero? failures) 0 1))
