;;; guix time-machine -C env/guix/channels-lock.scm -- repl -L src/guix -L src/guile test/guix/uraj/services/logs.scm
(use-modules (gnu) (gnu services) (gnu services admin) (gnu services shepherd)
             (guix gexp) (srfi srfi-1) (srfi srfi-26) (srfi srfi-64)
             (uraj services logs))

(test-begin "logs")
(unsetenv "TO_ISO")
(define storie (load (string-append (getcwd) "/env/guix/os/storie.scm")))
(define services (operating-system-services storie))
(define logs
  (service-value (fold-services services #:target-type service-log-service-type)))
(test-equal "storie's services own their log directories"
  '("/var/log/immich" "/var/log/new-api" "/var/log/paseo" "/var/log/paseo-relay")
  (sort (map service-log-directory logs) string<?))
(define rotation
  (service-value (fold-services services #:target-type log-rotation-service-type)))
(test-assert "container logs are rotated"
  (every (cut member <> (log-rotation-configuration-external-log-files rotation))
         '("/var/log/new-api/containers.log" "/var/log/immich/containers.log"
           "/var/log/paseo-relay/containers.log")))
(define shepherd
  (shepherd-configuration-services
   (service-value (fold-services services #:target-type shepherd-root-service-type))))
(define (log-file name)
  (let* ((service (find (lambda (s) (memq name (shepherd-service-provision s)))
                        shepherd))
         (tail (member #:log-file
                       (gexp->approximate-sexp (shepherd-service-start service)))))
    (and tail (cadr tail))))
(test-equal "Paseo logs inside its directory"
  '("/var/log/paseo/paseo.log" "/var/log/paseo/broker.log")
  (map log-file '(paseo paseo-broker)))

(define (extension target)
  (service-extension-compute
   (find (lambda (e) (eq? target (service-extension-target e)))
         (service-type-extensions service-log-service-type))))
(define new-api (service-log (name "new-api") (containers? #t)))
(define paseo (service-log (name "paseo")))
(test-equal "only container logs get an rsyslog route"
  '("rsyslog.d/new-api.conf")
  (map car ((extension etc-service-type) (list new-api paseo))))
(test-equal "the route stops at the service's group-owned file"
  "if $syslogfacility-text == \"local0\" and $syslogtag startswith \"new-api/\" then {
  action(type=\"omfile\" file=\"/var/log/new-api/containers.log\" fileGroup=\"log-readers\")
  stop
}
"
  (plain-file-content (cadar ((extension etc-service-type) (list new-api)))))
(test-equal "the Compose tag matches the route"
  "new-api/{{.Name}}"
  (assoc-ref (assoc-ref (cdr (compose-logging "new-api")) 'options) 'tag))
(for-each (lambda (name)
            (test-error (string-append "rejected log name " name) #t
              (service-log (name name))))
          '("" "a/b" "../x" "A" "a\"b"))

;; Execute the generated activation under a temporary /var/log, with a
;; supplementary group of the caller instead of root and log-readers.
(define directory (mkdtemp "/tmp/uraj-logs-activation-XXXXXX"))
(define (chownable? group)
  ;; Unmapped groups in a user namespace show up but cannot be used.
  (let* ((probe (mkstemp "/tmp/uraj-logs-probe-XXXXXX"))
         (file (port-filename probe)))
    (dynamic-wind
      (const #t)
      (lambda () (false-if-exception (begin (chown file -1 group) #t)))
      (lambda () (close-port probe) (delete-file file)))))
(define gid (or (find (lambda (g) (and (not (= g (getgid))) (chownable? g)))
                      (vector->list (getgroups)))
                (getgid)))
(define (adapt tree)
  (cond ((and (string? tree) (string-prefix? "/var/log" tree))
         (string-append directory (string-drop tree (string-length "/var/log"))))
        ((equal? tree '(group:gid (getgrnam "log-readers"))) gid)
        ((equal? tree '(chown directory 0 gid)) '(chown directory -1 gid))
        ((pair? tree) (cons (adapt (car tree)) (adapt (cdr tree))))
        (else tree)))
(define (activate)
  (eval (adapt (gexp->approximate-sexp
                ((extension activation-service-type) (list paseo))))
        (current-module)))
(define paseo-directory (string-append directory "/paseo"))
(define archive (string-append paseo-directory "/paseo.log.1"))
(dynamic-wind
  (lambda () #t)
  (lambda ()
    (activate)
    (test-equal "directory is setgid and group-readable only" #o2750
      (stat:perms (stat paseo-directory)))
    (test-equal "directory belongs to the reader group" gid
      (stat:gid (stat paseo-directory)))
    (chmod paseo-directory #o700)
    (activate)
    (test-equal "activation repairs an existing directory" #o2750
      (stat:perms (stat paseo-directory)))
    (close-port (open-output-file archive))
    (test-equal "files created later inherit the group" gid
      (stat:gid (stat archive)))
    (delete-file archive)
    (rmdir paseo-directory)
    (symlink "/tmp" paseo-directory)
    (test-error "activation refuses a symlink" #t (activate))
    (delete-file paseo-directory))
  (lambda ()
    (when (file-exists? archive) (delete-file archive))
    (false-if-exception (rmdir paseo-directory))
    (false-if-exception (delete-file paseo-directory))
    (rmdir directory)))
(define failures (test-runner-fail-count (test-runner-current)))
(test-end "logs")
(exit (if (zero? failures) 0 1))
