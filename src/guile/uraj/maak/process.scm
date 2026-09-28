(define-module (uraj maak process)
  #:use-module (ice-9 popen)
  #:use-module (rnrs io ports)
  #:use-module (maak dsl)
  #:export (run-command))

(define (run-inherited command)
  ;; Guile 3.0.9's system* installs SIG_IGN for SIGINT/SIGQUIT before
  ;; spawning, and the child inherits it.  Use the same primitive as
  ;; open-pipe*, with no pipes, to preserve terminal I/O and signal handling.
  (let ((pid ((@@ (ice-9 popen) piped-process)
              (car command) (cdr command) #f #f)))
    (cdr (waitpid pid))))

(define (run-to-file command filename)
  ;; Copy bytes through a pipe: rebinding a Scheme output port alone does
  ;; not redirect the child's stdout.  Keep stderr attached to the terminal.
  (call-with-output-file filename
    (lambda (output)
      (let ((input (apply open-pipe* OPEN_READ command))
            (status #f))
        (dynamic-wind
          (lambda () #t)
          (lambda ()
            (let loop ()
              (let ((chunk (get-bytevector-n input 65536)))
                (unless (eof-object? chunk)
                  (put-bytevector output chunk)
                  (loop)))))
          (lambda () (set! status (close-pipe input))))
        status))))

(define* (run-command command #:key output-file)
  "Execute COMMAND as an argument list, optionally saving stdout to OUTPUT-FILE.
Honor Maak's quiet and dry-run parameters; return #t on success."
  (log-info "~a argv: ~s~a\n"
            (if (dry-run?) "[DRY-RUN]" "Executing")
            command
            (if output-file (~ " -> ~s" output-file) ""))
  (if (dry-run?)
      #t
      (let ((status (if output-file
                        (run-to-file command output-file)
                        (run-inherited command))))
        ;; A signal-terminated child has no normal exit code.
        (if (equal? (status:exit-val status) 0)
            #t
            (error "Command failed" command
                   "exit code" (status:exit-val status)
                   "signal" (status:term-sig status))))))
