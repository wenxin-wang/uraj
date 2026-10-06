;;; A Guix system container for Paseo and its agents; no Docker runtime.
(define-module (uraj services paseo)
  #:use-module (gnu)
  #:use-module (gnu bootloader grub)
  #:use-module (gnu home)
  #:use-module (gnu home services)
  #:use-module (gnu home services shells)
  #:use-module (gnu packages admin)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages certs)
  #:use-module (gnu packages curl)
  #:use-module (gnu packages linux)
  #:use-module (gnu packages node)
  #:use-module (gnu packages nss)
  #:use-module (gnu packages python)
  #:use-module (gnu packages rust-apps)
  #:use-module (gnu packages ssh)
  #:use-module (gnu packages version-control)
  #:use-module (gnu services guix)
  #:use-module (gnu services shepherd)
  #:use-module (gnu system linux-container)
  #:use-module (gnu system shadow)
  #:use-module (gnu system vm)
  #:use-module (guix gexp)
  #:use-module (guix modules)
  #:use-module (guix records)
  #:use-module (uraj home llm)
  #:use-module (uraj packages llm)
  #:use-module (uraj system home)
  #:export (paseo-configuration paseo-service-type paseo-operating-system
            paseo-prepare-program paseo-container-program))

(define-record-type* <paseo-configuration>
  paseo-configuration make-paseo-configuration paseo-configuration?
  (package paseo-package (default paseo))
  (data-directory paseo-data-directory (default "/data/paseo"))
  (data-mount paseo-data-mount (default "/data"))
  (uid paseo-uid (default 1100))
  (parent-interface paseo-parent-interface (default "enp1s0"))
  (address paseo-address (default "172.31.0.7/24"))
  (gateway paseo-gateway (default "172.31.0.1"))
  (name-server paseo-name-server (default "172.31.0.1"))
  (relay-endpoint paseo-relay-endpoint (default "172.31.0.8:4000"))
  ;; Extra Home services on top of the agents and skills shared with desktop
  ;; Homes, e.g. more skills (extend home-agent-skills-service-type) or
  ;; non-secret agent configuration.
  (home-services paseo-home-services (default '()))
  ;; Tools the agents use; desktop Homes get them from their dev services.
  (packages paseo-packages
            (default (list git github-cli openssh curl ripgrep python node-lts)))
  (requirements paseo-requirements (default '(networking file-system-/data))))

(define (paseo-home config)
  (home-environment
   (packages (cons (paseo-package config) (paseo-packages config)))
   (services (cons* (service home-bash-service-type)
                    (append (agent-common-services)
                            (paseo-home-services config))))))

(define (paseo-guest-services config)
  (let* ((home (paseo-home config))
         (launch
          (mixed-text-file
           "paseo-daemon-run"
           ;; Guix profile scripts may expand unset search-path variables.
           ;; Enable nounset only after loading the Home environment.
           "#!" (file-append bash "/bin/bash") "\nset -e\n"
           "export HOME_ENVIRONMENT=" home "\n"
           ". " (file-append home "/setup-environment") "\n"
           "set -u\n"
           "export HOME=/home/paseo PASEO_HOME=/home/paseo/.paseo\n"
           "export PASEO_LISTEN=0.0.0.0:6767 PASEO_RELAY_ENABLED=true\n"
           "export PASEO_RELAY_ENDPOINT=" (paseo-relay-endpoint config) "\n"
           "export PASEO_RELAY_PUBLIC_ENDPOINT=$PASEO_RELAY_ENDPOINT\n"
           "export PASEO_RELAY_USE_TLS=false PASEO_RELAY_PUBLIC_USE_TLS=false\n"
           "export PASEO_WEB_UI_ENABLED=true\n"
           "export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt\n"
           "export GIT_SSL_CAINFO=$SSL_CERT_FILE\n"
           "export PASEO_PASSWORD=\"$(cat /home/paseo/.paseo-password)\"\n"
           "cd /workspace\nexec " (file-append (paseo-package config) "/bin/paseo")
           " daemon run\n")))
    (list
     (service guix-home-with-environment-service-type `(("paseo" ,home)))
     (simple-service 'paseo-resolver etc-service-type
       `(("resolv.conf" ,(plain-file "paseo-resolv.conf"
                          (string-append "nameserver " (paseo-name-server config) "\n")))))
     (simple-service 'paseo-guest shepherd-root-service-type
       (list
        (shepherd-service
         (provision '(paseo-network))
         (requirement '(user-processes))
         (documentation "Wait for the host to attach the macvlan interface.")
         (start #~(lambda _
                    (let loop ((remaining 60))
                      (cond
                       ((file-exists? "/sys/class/net/paseo0")
                        (invoke #$(file-append iproute "/sbin/ip")
                                "link" "set" "lo" "up")
                        (invoke #$(file-append iproute "/sbin/ip")
                                "address" "replace" #$(paseo-address config) "dev" "paseo0")
                        (invoke #$(file-append iproute "/sbin/ip")
                                "link" "set" "paseo0" "up")
                        (invoke #$(file-append iproute "/sbin/ip")
                                "route" "replace" "default" "via" #$(paseo-gateway config))
                        #t)
                       ((zero? remaining) (error "Paseo macvlan interface did not arrive"))
                       (else (sleep 1) (loop (- remaining 1)))))))
         (stop #~(lambda _ #f)))
        (shepherd-service
         (provision '(paseo-daemon))
         (requirement '(paseo-network guix-home-paseo))
         (documentation "Run Paseo without a desktop session, as the agent user.")
         (start #~(make-forkexec-constructor
                   (list #$(file-append bash "/bin/bash") #$launch)
                   #:user "paseo" #:group "paseo"
                   #:directory "/workspace"
                   #:environment-variables '("HOME=/home/paseo" "USER=paseo" "LOGNAME=paseo"
                                              "LANG=en_US.utf8" "PATH=/run/current-system/profile/bin")
                   #:log-file "/home/paseo/.paseo/shepherd.log"))
         (stop #~(make-kill-destructor))))))))

(define (paseo-operating-system config)
  (operating-system
    (host-name "paseo")
    (timezone "Asia/Shanghai")
    (locale "en_US.utf8")
    ;; Required fields; container-script substitutes the root and kernel.
    (bootloader (bootloader-configuration (bootloader grub-bootloader) (targets '("/dev/null"))))
    (file-systems (list (file-system (device "none") (mount-point "/") (type "dummy"))))
    (users (cons (user-account
                   (name "paseo") (uid (paseo-uid config)) (group "paseo")
                   (home-directory "/home/paseo") (shell (file-append bash "/bin/bash")))
                 %base-user-accounts))
    (groups (cons (user-group (name "paseo") (id (paseo-uid config))) %base-groups))
    (packages (cons* iproute util-linux %base-packages))
    (services (paseo-guest-services config))))

;; Keep the complete container system reachable from the host generation.
(define-gexp-compiler (paseo-container-compiler (config <paseo-configuration>) system target)
  (container-script
   (paseo-operating-system config)
   #:mappings
   (list (file-system-mapping
          (source (string-append (paseo-data-directory config) "/home"))
          (target "/home/paseo") (writable? #t))
         (file-system-mapping
          (source (string-append (paseo-data-directory config) "/workspace"))
          (target "/workspace") (writable? #t)))))

(define (paseo-container-program config) config)

(define (paseo-prepare-program config)
  (program-file
   "paseo-prepare"
   (with-imported-modules (source-module-closure '((guix build utils) (guix build syscalls)))
     #~(begin
         (use-modules (guix build utils) (guix build syscalls)
                      (rnrs io ports) (rnrs bytevectors) (ice-9 format) (srfi srfi-1))
         ;; Check before mkdir: a missing data mount must never populate /.
         (unless (any (lambda (mount)
                        (string=? (mount-point mount) #$(paseo-data-mount config)))
                      (mounts))
           (error "Paseo data filesystem is not mounted" #$(paseo-data-mount config)))
         (unless (file-exists? #$(string-append "/sys/class/net/" (paseo-parent-interface config)))
           (error "Paseo macvlan parent is missing"))
         (umask #o077)
         (let* ((data #$(paseo-data-directory config))
                (home (string-append data "/home"))
                (state (string-append home "/.paseo"))
                (password (string-append home "/.paseo-password"))
                (settings (string-append state "/config.json")))
           (for-each
            (lambda (path)
              (if (file-exists? path)
                  (unless (and (eq? 'directory (stat:type (lstat path)))
                               (= (stat:uid (stat path)) #$(paseo-uid config)))
                    (error "Existing Paseo directory has unexpected ownership or type" path))
                  (begin (mkdir-p path) (chown path #$(paseo-uid config) #$(paseo-uid config)))))
            (list data home state (string-append data "/workspace")))
           (unless (file-exists? password)
             (let ((bytes (call-with-input-file "/dev/urandom"
                            (lambda (port) (get-bytevector-n port 32)))))
               (call-with-output-file password
                 (lambda (port)
                   (do ((i 0 (+ i 1))) ((= i 32))
                     (format port "~2,'0x" (bytevector-u8-ref bytes i)))
                   (newline port)))
               (chown password #$(paseo-uid config) #$(paseo-uid config))))
           (unless (and (eq? 'regular (stat:type (lstat password)))
                        (= (stat:uid (lstat password)) #$(paseo-uid config)))
             (error "Paseo password must be a regular file owned by paseo"))
           (when (zero? (stat:size (stat password)))
             (error "Paseo password file is empty"))
           (chmod password #o600)
           (unless (file-exists? settings)
             (call-with-output-file settings
               (lambda (port)
                 (display "{\"version\":1,\"worktrees\":{\"root\":\"/workspace/worktrees\"}}\n" port)))
             (chown settings #$(paseo-uid config) #$(paseo-uid config))))))))

(define (paseo-host-services config)
  (list
   (shepherd-service
    (provision '(paseo))
    (requirement (paseo-requirements config))
    (documentation "Run the Paseo Guix system container on its own macvlan address.")
    (modules '((shepherd service) (guix build utils) (ice-9 rdelim)))
    (start
     #~(lambda _
         (invoke #$(paseo-prepare-program config))
         (when (file-exists? "/sys/class/net/paseo0")
           (error "Refusing to replace an existing paseo0 interface"))
         (mkdir-p "/run/paseo-container")
         (chmod "/run/paseo-container" #o700)
         (when (file-exists? "/run/paseo-container/pid")
           (delete-file "/run/paseo-container/pid"))
         (let ((pid ((make-forkexec-constructor
                      (list #$config "--pid-file=/run/paseo-container/pid")
                      #:log-file "/var/log/paseo-container.log")))
               (created? #f))
           (unless pid (error "Could not start Paseo container"))
           (catch #t
             (lambda ()
               (let ((container-pid
                      (let loop ((remaining 60))
                        (let ((value (and (file-exists? "/run/paseo-container/pid")
                                          (call-with-input-file "/run/paseo-container/pid" read))))
                          (cond
                           ((and (integer? value) (> value 1)) (number->string value))
                           ((zero? remaining) (error "Paseo container startup timed out"))
                           (else (sleep 1) (loop (- remaining 1))))))))
                 (invoke #$(file-append iproute "/sbin/ip")
                         "link" "add" "link" #$(paseo-parent-interface config)
                         "name" "paseo0" "type" "macvlan" "mode" "bridge")
                 (set! created? #t)
                 (invoke #$(file-append iproute "/sbin/ip")
                         "link" "set" "paseo0" "netns" container-pid)
                 (set! created? #f)
                 ;; Probe from the namespace: the macvlan host cannot reach .7.
                 (let loop ((remaining 90))
                   (if (zero? (system* #$(file-append util-linux "/bin/nsenter")
                                       "--target" container-pid "--net" "--"
                                       #$(file-append curl "/bin/curl") "--silent" "--fail"
                                       "--max-time" "2" "--output" "/dev/null"
                                       "http://127.0.0.1:6767/api/health"))
                       pid
                       (if (zero? remaining)
                           (error "Paseo daemon health check timed out")
                           (begin (sleep 1) (loop (- remaining 1))))))))
             (lambda args
               ((make-kill-destructor) pid)
               (when created?
                 (system* #$(file-append iproute "/sbin/ip") "link" "delete" "paseo0"))
               (apply throw args))))))
    (stop #~(make-kill-destructor)))))

(define (paseo-accounts config)
  (list (user-group (name "paseo") (id (paseo-uid config)) (system? #t))
        (user-account
         (name "paseo") (uid (paseo-uid config)) (group "paseo") (system? #t)
         (home-directory (string-append (paseo-data-directory config) "/home"))
         (create-home-directory? #f)
         (shell (file-append shadow "/sbin/nologin")))))

(define paseo-service-type
  (service-type
   (name 'paseo)
   (extensions (list (service-extension shepherd-root-service-type paseo-host-services)
                     (service-extension account-service-type paseo-accounts)))
   (default-value (paseo-configuration))
   (description "Paseo and coding agents in a persistent Guix container with macvlan networking.")))
