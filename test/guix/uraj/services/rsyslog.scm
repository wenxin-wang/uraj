;; Run with the pinned channels and -L src/guix -L src/guile.
(use-modules (gnu) (gnu services) (gnu services base) (gnu services admin)
             (gnu services shepherd) (gnu system accounts)
             (guix gexp) (ice-9 ftw) (ice-9 rdelim) (srfi srfi-1) (srfi srfi-64)
             (uraj system base))

(test-begin "rsyslog")
(define desktop (load (string-append (getcwd) "/env/guix/os/lappie.scm")))
(define services (operating-system-services desktop))
(define syslogs
  (filter (lambda (s) (eq? (service-kind s) syslog-service-type)) services))
(test-equal "one external syslog service" 1 (length syslogs))
(test-assert "built-in logger removed"
  (not (any (lambda (s) (eq? (service-kind s) shepherd-system-log-service-type))
            services)))
(define config (service-value (car syslogs)))
(test-equal "daemon and supervisor agree on PID path"
  (list "-i" (syslog-configuration-pid-file config))
  (syslog-configuration-extra-options config))
(test-assert "configuration source exists"
  (file-exists? (local-file-absolute-file-name
                 (syslog-configuration-config-file config))))
(define rotation
  (service-value (fold-services services #:target-type log-rotation-service-type)))
(test-equal "default compression retained" 'zstd
  (log-rotation-configuration-compression rotation))
(test-assert "syslog files retain native external rotation"
  (every (lambda (file)
           (member file (log-rotation-configuration-external-log-files rotation)))
         '("/var/log/messages" "/var/log/secure" "/var/log/debug" "/var/log/maillog")))
(define user
  (find (lambda (u) (string=? "wenxin" (user-account-name u)))
        (operating-system-users desktop)))
(test-equal "desktop inherits shared groups and appends device groups"
  '("wheel" "log-readers" "netdev" "audio" "video" "cgroup")
  (user-account-supplementary-groups user))
(test-assert "desktop receives log-readers membership"
  (member "log-readers" (user-account-supplementary-groups user)))

;; Execute the generated activation with only the path and group substituted.
(define directory (mkdtemp "/tmp/uraj-rsyslog-activation-XXXXXX"))
(define file (string-append directory "/messages"))
(define activation
  (service-value
   (find (lambda (s) (eq? 'readable-messages (service-type-name (service-kind s))))
         services)))
(define (adapt tree)
  (cond ((equal? tree "/var/log") directory)
        ((equal? tree "/var/log/messages") file)
        ((equal? tree '(group:gid (getgrnam "log-readers"))) (getgid))
        ((pair? tree) (cons (adapt (car tree)) (adapt (cdr tree))))
        (else tree)))
(define (activate)
  (eval (adapt (gexp->approximate-sexp activation)) (current-module)))
(dynamic-wind
  (lambda () #t)
  (lambda ()
    (activate)
    (test-equal "activation creates messages as 0640" #o640 (stat:perms (stat file)))
    (call-with-output-file file (lambda (port) (display "existing content\n" port)))
    (chmod file #o600)
    (activate)
    (test-equal "activation repairs existing mode" #o640 (stat:perms (stat file)))
    (test-equal "activation preserves content" "existing content"
      (call-with-input-file file read-line))
    (delete-file file)
    (symlink "/dev/null" file)
    (test-error "activation refuses symlink" #t (activate)))
  (lambda () (delete-file file) (rmdir directory)))
(define failures (test-runner-fail-count (test-runner-current)))
(test-end "rsyslog")
(exit (if (zero? failures) 0 1))
