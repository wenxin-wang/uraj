;;; Per-service log directories under /var/log that log-readers read without
;;; sudo, and Compose output routed into them through syslog.
(define-module (uraj services logs)
  #:use-module (gnu services)
  #:use-module (gnu services admin)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:use-module (srfi srfi-1)
  #:export (service-log service-log? service-log-name
            service-log-containers? service-log-directory
            service-log-containers-file service-log-service-type
            compose-logging))

(define-record-type* <service-log>
  service-log make-service-log service-log?
  ;; Names /var/log/NAME/ and, with CONTAINERS?, the Compose project.
  (name service-log-name (sanitize sanitize-service-log-name))
  ;; Collect output tagged by compose-logging into containers.log.
  (containers? service-log-containers? (default #f)))

(define (sanitize-service-log-name name)
  ;; The name lands in a path and in an rsyslog string literal.
  (unless (and (string? name) (not (string-null? name))
               (string-every (char-set-union char-set:lower-case
                                             char-set:digit (char-set #\-))
                             name))
    (error "Invalid service log name" name))
  name)

(define (service-log-directory log)
  (string-append "/var/log/" (service-log-name log)))

(define (service-log-containers-file log)
  (string-append (service-log-directory log) "/containers.log"))

(define (compose-logging name)
  "Return the Compose logging entry sending a container's output to the
containers.log of the service log NAME."
  `(logging
    . ((driver . "syslog")
       (options
        . ((syslog-address . "unixgram:///dev/log")
           (syslog-facility . "local0")
           (syslog-format . "rfc3164")
           ;; Engine 20.10+ keeps a local copy, so `compose logs' still works.
           (tag . ,(string-append name "/{{.Name}}"))
           ;; A stalled syslogd drops output instead of blocking containers.
           (mode . "non-blocking"))))))

(define (service-log-activation logs)
  ;; Setgid: files that root creates later, such as rotated and compressed
  ;; archives or Shepherd's reopened logs, inherit the group too.
  #~(let ((gid (group:gid (getgrnam "log-readers"))))
      (for-each
       (lambda (directory)
         (unless (file-exists? "/var/log") (mkdir "/var/log" #o755))
         (unless (file-exists? directory) (mkdir directory #o750))
         (unless (eq? 'directory (stat:type (lstat directory)))
           (error "Refusing non-directory log path" directory))
         (chown directory 0 gid)
         (chmod directory #o2750))
       '#$(map service-log-directory logs))))

(define (service-log-rsyslog-files logs)
  (map (lambda (log)
         (let ((name (service-log-name log)))
           (list (string-append "rsyslog.d/" name ".conf")
                 (plain-file
                  (string-append "rsyslog-" name ".conf")
                  (string-append
                   "if $syslogfacility-text == \"local0\" and $syslogtag startswith \""
                   name "/\" then {\n"
                   "  action(type=\"omfile\" file=\"" (service-log-containers-file log)
                   "\" fileGroup=\"log-readers\")\n"
                   "  stop\n"
                   "}\n")))))
       (filter service-log-containers? logs)))

(define service-log-service-type
  (service-type
   (name 'service-log)
   (extensions
    (list (service-extension activation-service-type service-log-activation)
          (service-extension etc-service-type service-log-rsyslog-files)
          (service-extension log-rotation-service-type
                             (lambda (logs)
                               (map service-log-containers-file
                                    (filter service-log-containers? logs))))))
   (compose concatenate)
   (extend append)
   (default-value '())
   (description "Group-readable /var/log/NAME/ directories, with Compose
output routed into them by rsyslog.")))
