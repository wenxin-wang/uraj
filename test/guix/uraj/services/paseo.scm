;;; guix time-machine -C env/guix/channels-lock.scm -- repl -L src/guix -L src/guile test/guix/uraj/services/paseo.scm
(use-modules (gnu) (gnu services) (gnu services shepherd)
             (guix gexp) (srfi srfi-1) (srfi srfi-64)
             (uraj services paseo))

(define (services os)
  (shepherd-configuration-services
   (service-value (fold-services (operating-system-services os)
                                #:target-type shepherd-root-service-type))))
(define (lookup all name)
  (find (lambda (s) (memq name (shepherd-service-provision s))) all))

(define guest (services (paseo-operating-system (paseo-configuration))))

;; Run the actual preparation gexp with fake mounts and filesystem writes.
;; This checks the guards and that existing credentials/config are preserved.
(define* (prepare #:key (mounted? #t) (nic? #t) (existing? #f) (owner 1100))
  (let ((module (make-fresh-user-module)) (writes '()) (contents '()))
    (for-each (lambda (interface) (module-use! module (resolve-interface interface)))
              '((srfi srfi-1) (ice-9 format) (rnrs io ports) (rnrs bytevectors)))
    (define (define! name value) (module-define! module name value))
    (define! 'mounts (lambda () (if mounted? '("/data") '())))
    (define! 'mount-point identity)
    (define! 'file-exists?
      (lambda (path) (if (string-prefix? "/sys/" path) nic? existing?)))
    (define! 'umask (lambda _ #t))
    (define! 'mkdir-p (lambda (path) (set! writes (cons path writes))))
    (define! 'chmod (lambda _ #t))
    (define! 'chown (lambda _ #t))
    (define! 'stat identity)
    (define! 'lstat identity)
    (define! 'stat:type (lambda (path)
                          (if (string-suffix? ".paseo-password" path) 'regular 'directory)))
    (define! 'stat:uid (lambda _ owner))
    (define! 'stat:size (lambda _ 65))
    (define! 'call-with-output-file
      (lambda (path proc)
        (set! writes (cons path writes))
        (set! contents (cons (cons path (call-with-output-string proc)) contents))))
    (let* ((body (gexp->approximate-sexp
                  (program-file-gexp (paseo-prepare-program (paseo-configuration)))))
           (ok? (catch #t
                  (lambda () (eval `(begin ,@(cddr body)) module) #t)
                  (lambda _ #f))))
      (list ok? writes contents))))

(test-begin "paseo")
(test-assert "daemon waits for networking and activated agent home"
  (every (lambda (name)
           (memq name (shepherd-service-requirement (lookup guest 'paseo-daemon))))
         '(paseo-network guix-home-paseo)))
(test-assert "container does not start Docker or a Guix build daemon"
  (not (any (lambda (name) (lookup guest name)) '(dockerd containerd guix-daemon))))
(test-equal "missing mount fails before writes" '(#f () ()) (prepare #:mounted? #f))
(test-equal "missing NIC fails before writes" '(#f () ()) (prepare #:nic? #f))
(test-equal "wrong ownership fails before writes" '(#f () ())
  (prepare #:existing? #t #:owner 1000))
(test-equal "restart preserves password and writable config" '(#t () ())
  (prepare #:existing? #t))
(let ((result (prepare)))
  (test-assert "fresh home initialized" (car result))
  (test-equal "password has 256 bits in hex plus newline" 65
    (string-length (assoc-ref (caddr result) "/data/paseo/home/.paseo-password")))
  (test-assert "worktrees live in the persistent workspace"
    (string-contains (assoc-ref (caddr result) "/data/paseo/home/.paseo/config.json")
                     "\"root\":\"/workspace/worktrees\"")))
(define failures (test-runner-fail-count (test-runner-current)))
(test-end "paseo")
(exit (if (zero? failures) 0 1))
