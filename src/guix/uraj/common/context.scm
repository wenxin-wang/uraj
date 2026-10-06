(define-module (uraj common context)
  #:use-module (gnu system accounts)
  #:use-module (guix records)
  #:use-module (ice-9 rdelim)
  #:use-module (srfi srfi-13)
  #:export (home-target
            home-target?
            home-target-foreign?
            home-target-state-directory
            home-target-os-release
            home-target-systemd?
            guix-system-home-target
            foreign-home-target
            %home-target
            current-home-target
            home-state-directory))

;;; The machine a Home environment is built for.  Only foreign-home-target
;;; inspects the evaluating machine: a Guix System Home is often built on
;;; another machine (a developer's Ubuntu box for the installers), whose
;;; os-release, init or environment must not leak into the target.  Lower
;;; layers interpret these facts, e.g. (uraj packages window-managers)
;;; maps OS-RELEASE to noctalia's host PAM closure.

(define-record-type* <home-target>
  home-target make-home-target
  home-target?
  (foreign?        home-target-foreign?)        ;Home on a foreign distro?
  (state-directory home-target-state-directory) ;the target user's XDG state
  (os-release      home-target-os-release       ;alist of /etc/os-release
                   (default '()))
  (systemd?        home-target-systemd?         ;systemd is the init?
                   (default #f)))

(define (guix-system-home-target user)
  "Return the target of a Home environment embedded in Guix System for USER,
a <user-account>.  Nothing is read from the evaluating machine."
  (home-target
   (foreign? #f)
   (state-directory
    (string-append (user-account-home-directory user) "/.local/state"))))

(define (read-os-release file)
  "Return the KEY=VALUE lines of FILE as an alist, or '() if FILE is missing."
  (define (strip-quotes value)
    ;; Strip quotes, e.g. VERSION_ID="24.04".
    (if (and (> (string-length value) 1)
             (char=? #\" (string-ref value 0))
             (char=? #\" (string-ref value (1- (string-length value)))))
        (substring value 1 (1- (string-length value)))
        value))
  (if (file-exists? file)
      (call-with-input-file file
        (lambda (port)
          (let loop ((line (read-line port)) (fields '()))
            (cond ((eof-object? line) (reverse fields))
                  ((string-index line #\=)
                   => (lambda (i)
                        (loop (read-line port)
                              (cons (cons (substring line 0 i)
                                          (strip-quotes (substring line (1+ i))))
                                    fields))))
                  (else (loop (read-line port) fields))))))
      '()))

(define (foreign-home-target)
  "Return the target of a foreign Home evaluated by its owner on the machine
it configures, as detected from that machine and the user's environment."
  (let ((home (or (getenv "HOME") (error "Foreign Home requires HOME")))
        (state (getenv "XDG_STATE_HOME")))
    (home-target
     (foreign? #t)
     (state-directory (if (and state (not (string-null? state)))
                          state
                          (string-append home "/.local/state")))
     (os-release (read-os-release "/etc/os-release"))
     (systemd? (file-exists? "/run/systemd/system")))))

;; Configuration-time context.  Bind this around Home service construction;
;; deferred callbacks and gexps must capture the resulting values instead.
(define %home-target (make-parameter #f))

(define (current-home-target)
  "Return the bound Home target; there is no default, so construction
outside a context fails instead of silently assuming one kind of host."
  (or (%home-target)
      (error "Home services must be constructed under %home-target")))

(define (home-state-directory)
  "Return the target user's state directory in the current context."
  (home-target-state-directory (current-home-target)))
