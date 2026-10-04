(define-module (uraj common context)
  #:use-module (gnu system accounts)
  #:export (%main-user %for-foreign-home home-state-directory))

;; Configuration-time context.  Bind these around service construction;
;; deferred callbacks and gexps must capture the resulting values instead.
;; A missing main user is allowed for a foreign Home evaluated as its owner.
(define %main-user (make-parameter #f))
(define %for-foreign-home (make-parameter #f))

(define (home-state-directory)
  "Return the target user's state directory in the current context.
Only foreign Home configurations may consult the evaluating user's environment."
  (or (and (%for-foreign-home)
           (let ((state (getenv "XDG_STATE_HOME")))
             (and state (not (string-null? state)) state)))
      (string-append
       (cond ((%main-user) => user-account-home-directory)
             ((%for-foreign-home)
              (or (getenv "HOME") (error "Foreign Home requires HOME")))
             (else (error "System Home requires %main-user")))
       "/.local/state")))
