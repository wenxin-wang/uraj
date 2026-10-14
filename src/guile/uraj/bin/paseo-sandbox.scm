;;; Host-only, data-only policy for the Paseo daemon's mounts, credentials and
;;; SSH agent.
(define-module (uraj bin paseo-sandbox)
  #:use-module (ice-9 match)
  #:use-module (ice-9 rdelim)
  #:use-module (srfi srfi-1)
  #:use-module (uraj bin contained-agent)
  #:use-module (uraj bin contained-ssh)
  #:export (paseo-sandbox-main))

(define* (paseo-sandbox-main file tools
                             #:key (github-secrets (%github-secrets)))
  (let* ((clauses (read-all file))
         (policy (ssh-policy clauses))
         ;; Validate all mounts before loading any key. The same denied paths
         ;; and read-only/read-write syntax apply as for contained-agent.
         (options
          (append-map
           (lambda (clause)
             (match clause
               (('ssh-agent _ ...) '())
               (((or 'env 'github 'git-credential) _ ...) '())
               (('guix-daemon) (error "Paseo does not expose the Guix daemon"))
               (('git-hooks _ ...) (error "Paseo does not set Git hooks"))
               (_ (clause-options file clause))))
           clauses))
         (directory
          (and policy
               (ssh-ensure (getenv "HOME") policy tools
                           (getenv "CONTAINED_AGENT_SSH_RUNTIME_DIRECTORY"))))
         ;; After SSH unlocking; the daemon command below inherits the
         ;; environment this sets.
         (credentials (parameterize ((%github-secrets github-secrets))
                        (credential-options
                         (map (lambda (clause) (cons file clause)) clauses)
                         "/run/paseo"))))
    ;; A NUL-delimited result keeps spaces/newlines literal without evaluating
    ;; config as Scheme or shell. stdout is reserved for this one response.
    (for-each (lambda (value) (display value) (write-char #\nul))
              (cons (or directory "") (append options credentials)))
    (write-char #\nul)
    (force-output)
    ;; Replace this namespace's workload with the daemon. Its SSH agents stay
    ;; in the same supervised namespace; workload exit tears down all of them.
    (let loop ((arguments '()))
      (let ((argument (read-delimited (string #\nul))))
        (cond
         ((eof-object? argument) (error "Paseo launcher disconnected"))
         ((string-null? argument)
          (when (null? arguments) (error "Missing Paseo command"))
          (setenv "TMPDIR" (getenv "PASEO_DAEMON_TMPDIR"))
          (unsetenv "PASEO_DAEMON_TMPDIR")
          (unsetenv "CONTAINED_AGENT_SSH_RUNTIME_DIRECTORY")
          (let ((command (reverse arguments)))
            (apply execlp (car command) command)))
         (else (loop (cons argument arguments))))))))
