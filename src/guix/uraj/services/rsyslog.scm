(define-module (uraj services rsyslog)
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu services shepherd)
  #:use-module (gnu system accounts)
  #:use-module (gnu system shadow)
  #:use-module (gnu packages logging)
  #:use-module (guix gexp)
  #:export (rsyslog-services %rsyslog-config-file))

(define %rsyslog-config-file
  (local-file "rsyslog.conf"))

(define %rsyslog-service
  (service syslog-service-type
    (syslog-configuration
      (syslogd (file-append rsyslog "/sbin/rsyslogd"))
      (config-file %rsyslog-config-file)
      ;; This service waits for a PID file; let rsyslog daemonize normally.
      (pid-file "/var/run/syslog.pid")
      (extra-options '("-i" "/var/run/syslog.pid")))))

(define (rsyslog-services services)
  "Replace the built-in logger, retaining Guix's external-log rotation."
  (cons*
   (simple-service 'log-readers account-service-type
     (list (user-group (name "log-readers") (system? #t))))
   (simple-service 'readable-messages activation-service-type
     #~(begin
         (unless (file-exists? "/var/log") (mkdir "/var/log" #o755))
         ;; rsyslog's fileGroup applies only on creation.  Migrate the current
         ;; file too, without changing archives or following links.
         (let ((fd (open-fdes "/var/log/messages"
                              (logior O_RDONLY O_CREAT O_NOFOLLOW O_NONBLOCK)
                              #o640)))
           (dynamic-wind
             (lambda () #t)
             (lambda ()
               (let ((info (stat fd)))
                 (unless (and (eq? 'regular (stat:type info))
                              (= 1 (stat:nlink info)))
                   (error "Refusing non-regular or linked /var/log/messages")))
               (chown fd -1 (group:gid (getgrnam "log-readers")))
               (chmod fd #o640))
             (lambda () (close-fdes fd))))))
   (map (lambda (entry)
          (if (eq? (service-kind entry) shepherd-system-log-service-type)
              %rsyslog-service
              entry))
        services)))
