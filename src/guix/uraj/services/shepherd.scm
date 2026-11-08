;;; Shepherd helpers shared by uraj services.
(define-module (uraj services shepherd)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:export (restart-with-arguments-action))

(define restart-with-arguments-action
  ;; Shepherd's built-in restart passes its arguments only to the very
  ;; service object it stopped.  After a reconfigure, stopping registers the
  ;; new definition instead, so `herd restart SERVICE ARG' silently starts it
  ;; without ARG.  stop-service returns the service, or its replacement,
  ;; followed by the stopped dependents; restart whatever comes first.
  ;; Unlike the built-in action, transient dependents are started again.
  (shepherd-action
   (name 'restart)
   (documentation "Restart the service, passing the arguments to its start
procedure even when a reconfigure replaced its definition.")
   (procedure
    #~(lambda (running . args)
        (let ((stopped (stop-service (current-service))))
          (and stopped
               (begin
                 (apply start-service (car stopped) args)
                 (for-each start-service (cdr stopped))
                 #t)))))))
