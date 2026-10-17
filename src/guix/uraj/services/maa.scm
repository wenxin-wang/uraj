;;; Scheduled MAA controller for hypie's private redroid instance.
(define-module (uraj services maa)
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu services mcron)
  #:use-module (gnu system shadow)
  #:use-module (gnu packages admin)
  #:use-module (gnu packages base)
  #:use-module (gnu packages linux)
  #:use-module (gnu packages nss)
  #:use-module (guix gexp)
  #:use-module (uraj packages android)
  #:use-module (uraj packages maa)
  #:use-module (uraj utils file path)
  #:export (%maa-daily-job %maa-daily-command %maa-services))

(define %maa-config
  (file-union
   "maa-config"
   `(("cli.toml" ,(local-file (project-path "env/maa/cli.toml")))
     ("profiles/default.toml"
      ,(local-file (project-path "env/maa/profiles/default.toml")))
     ("tasks/daily.toml"
      ,(local-file (project-path "env/maa/tasks/daily.toml"))))))

(define %maa-run
  (program-file
   "maa-run-daily"
   #~(begin
       ;; MaaCore's first adb child can leave its pipe open in the server,
       ;; delaying connection until the command timeout. Start it separately.
       (unless (zero? (system* #$(file-append android-platform-tools "/bin/adb")
                              "start-server"))
         (error "Could not start the MAA ADB server"))
       (execl #$(file-append maa-assistant-arknights "/bin/maa")
              "maa" "run" "daily" "--batch" "--verbose" "--log-file"))))

(define %maa-daily-command
  (program-file
   "maa-daily"
   #~(begin
       (setenv "HOME" "/var/lib/maa")
       (setenv "PATH" #$(file-append android-platform-tools "/bin"))
       (setenv "MAA_CONFIG_DIR" #$%maa-config)
       (setenv "XDG_DATA_HOME" "/var/lib/maa/data")
       (setenv "XDG_CACHE_HOME" "/var/lib/maa/cache")
       (setenv "XDG_STATE_HOME" "/var/lib/maa/state")
       (setenv "SSL_CERT_FILE"
               #$(file-append nss-certs "/etc/ssl/certs/ca-certificates.crt"))
       ;; Keep this user's server separate from interactive adb clients.
       (setenv "ANDROID_ADB_SERVER_PORT" "5038")
       (chdir "/var/lib/maa")
       (umask #o077)
       ;; Lock includes resource updates and the whole run.  A stuck run
       ;; expires well before the next slot; timeout kills the process group.
       (execl #$(file-append util-linux "/bin/flock") "flock"
              "--nonblock" "--close" "/var/lib/maa/daily.lock"
              #$(file-append coreutils "/bin/timeout")
              "--kill-after=30s" "2h"
              #$%maa-run))))

;; mcron uses the system timezone: hypie inherits Asia/Shanghai.
(define %maa-daily-job
  #~(job '(next-hour '(2 5 14 21)) #$%maa-daily-command #:user "maa"))

(define %maa-services
  (list
   (simple-service 'maa-account account-service-type
     (list (user-group (name "maa") (system? #t))
           (user-account
             (name "maa") (group "maa") (system? #t)
             (comment "MAA daily controller")
             (home-directory "/var/lib/maa")
             (shell (file-append shadow "/sbin/nologin")))))
   (simple-service 'maa-state activation-service-type
     (with-imported-modules '((guix build utils))
       #~(begin
           (use-modules (guix build utils))
           (mkdir-p "/var/lib/maa")
           (let ((user (getpwnam "maa")))
             (chown "/var/lib/maa" (passwd:uid user) (passwd:gid user)))
           (chmod "/var/lib/maa" #o700))))
   (simple-service 'maa-daily mcron-service-type (list %maa-daily-job))))
