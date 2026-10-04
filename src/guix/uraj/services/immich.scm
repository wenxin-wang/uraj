;;; Immich on a single macvlan address, without Docker bridge/NAT rules.
(define-module (uraj services immich)
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu services docker)
  #:use-module (gnu services shepherd)
  #:use-module (gnu system file-systems)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:use-module (json)
  #:use-module (srfi srfi-1)
  #:use-module (uraj packages docker)
  #:export (immich-configuration immich-service-type
            immich-docker-service-type %immich-docker-configuration
            immich-compose-file immich-prepare-program))

(define-record-type* <immich-configuration>
  immich-configuration make-immich-configuration immich-configuration?
  (version immich-version (default "v3.2.4"))
  (data-directory immich-data-directory (default "/data/immich"))
  (media-directory immich-media-directory (default "/core-data/archive/immich"))
  (archive-dataset immich-archive-dataset (default "core-data/archive"))
  (archive-mount immich-archive-mount (default "/core-data/archive"))
  (parent-interface immich-parent-interface (default "enp1s0"))
  (subnet immich-subnet (default "172.31.0.0/24"))
  (gateway immich-gateway (default "172.31.0.1"))
  (address immich-address (default "172.31.0.6"))
  (external-network immich-external-network (default #f))
  ;; #f generates a persistent secret outside the store on first startup.
  ;; A string names a runtime file, e.g. a sops-guix decrypted secret.
  (database-password-file immich-password-file (default #f))
  (requirements immich-requirements
                (default '(zfs-data-ready file-system-/data)))
  (secret-requirements immich-secret-requirements (default '())))

;; Guix's daemon service unnecessarily requires desktop session services.
;; Keep its activation, account and package integration, but remove elogind
;; and D-Bus from the headless daemon's prerequisites.
(define immich-docker-service-type
  (service-type
   (inherit docker-service-type)
   (name 'immich-docker)
   (extensions
    (cons (service-extension file-system-service-type (const %control-groups))
     (map (lambda (extension)
           (if (eq? (service-extension-target extension) shepherd-root-service-type)
               (service-extension
                shepherd-root-service-type
                (lambda (config)
                  (map (lambda (s)
                         (shepherd-service
                          (inherit s)
                          (requirement
                           (remove (lambda (r) (memq r '(elogind dbus-system)))
                                   (shepherd-service-requirement s)))))
                       ((service-extension-compute extension) config))))
               extension))
         (service-type-extensions docker-service-type))))))

(define %immich-docker-configuration
  (docker-configuration
   (docker-cli docker-full)
   (enable-iptables? #f)
   (enable-proxy? #f)
   ;; iptables and userland-proxy are already passed on the command line.
   (config-file
    (plain-file "immich-docker-daemon.json"
                "{\"bridge\":\"none\",\"ip6tables\":false,\"ip-forward\":false}\n"))))

(define (bind source target)
  `((type . "bind") (source . ,source) (target . ,target)
    (bind . ((create_host_path . #f)))))

(define (immich-compose-file config)
  ;; Based on the v3.2.4 release Compose, with one shared network namespace.
  ;; Keep the upstream image commands/healthchecks except Postgres binding.
  ;; on-failure restarts crashes but DOES NOT resurrect containers on daemon
  ;; startup: Shepherd must check mounts and secrets before starting them.
  (let* ((data (immich-data-directory config))
         (common '((network_mode . "service:network") (restart . "on-failure")))
         (network-dependency '((network . ((condition . "service_started")))))
         (secret #("db-password")))
    (plain-file
     "immich-compose.json"
     (scm->json-string
      `((name . "immich")
        (services .
         ((network .
           ((image . "registry.k8s.io/pause:3.10@sha256:ee6521f290b2168b6e0935a181d4cff9be1ac3f505666ef0e3c98fae8199917a")
            (restart . "on-failure")
            ;; Docker container network mode inherits the anchor's hosts file.
            ;; Preserve Immich's default ML URL without freezing UI settings.
            (extra_hosts . #("immich-machine-learning=127.0.0.1"))
            (networks . ((lan . ((ipv4_address . ,(immich-address config))))))))
          (immich-server .
           (,@common
            (image . ,(string-append "ghcr.io/immich-app/immich-server:" (immich-version config)))
            (environment . ((TZ . "Asia/Shanghai")
                            (DB_HOSTNAME . "127.0.0.1")
                            (DB_USERNAME . "postgres")
                            (DB_DATABASE_NAME . "immich")
                            (DB_PASSWORD_FILE . "/run/secrets/db-password")
                            (REDIS_HOSTNAME . "127.0.0.1")))
            (secrets . ,secret)
            (volumes . ,(vector (bind (immich-media-directory config) "/data")))
            (depends_on . ((network . ((condition . "service_started")))
                           (database . ((condition . "service_healthy")))
                           (redis . ((condition . "service_healthy")))))
            (healthcheck . ((disable . #f)))))
          (immich-machine-learning .
           (,@common
            (image . ,(string-append "ghcr.io/immich-app/immich-machine-learning:" (immich-version config)))
            (environment . ((TZ . "Asia/Shanghai") (IMMICH_HOST . "127.0.0.1")))
            (volumes . ,(vector (bind (string-append data "/model-cache") "/cache")))
            (depends_on . ,network-dependency)
            (healthcheck . ((disable . #f)))))
          (redis .
           (,@common
            (image . "docker.io/valkey/valkey:9@sha256:70739f85ad2ee01a726a965584a0f94895f01b0c60b3cc8b0aeef11eaa6888cf")
            (command . #("valkey-server" "--bind" "127.0.0.1"))
            (depends_on . ,network-dependency)
            (healthcheck . ((test . #("CMD" "redis-cli" "ping"))))))
          (database .
           (,@common
            (image . "ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0@sha256:bcf63357191b76a916ae5eb93464d65c07511da41e3bf7a8416db519b40b1c23")
            (command . #("postgres" "-c" "config_file=/etc/postgresql/postgresql.conf"
                         "-c" "listen_addresses=127.0.0.1"))
            (environment . ((POSTGRES_PASSWORD_FILE . "/run/secrets/db-password")
                            (POSTGRES_USER . "postgres") (POSTGRES_DB . "immich")
                            (POSTGRES_INITDB_ARGS . "--data-checksums")))
            (secrets . ,secret)
            (volumes . ,(vector (bind (string-append data "/postgres") "/var/lib/postgresql/data")))
            (shm_size . "128mb")
            (depends_on . ,network-dependency)
            (healthcheck . ((disable . #f)))))))
        (networks .
         ((lan . ,(if (immich-external-network config)
                      `((external . #t) (name . ,(immich-external-network config)))
                      `((driver . "macvlan")
                        (driver_opts . ((parent . ,(immich-parent-interface config))
                                        (macvlan_mode . "bridge")))
                        (ipam . ((config . ,(vector
                                            `((subnet . ,(immich-subnet config))
                                              (gateway . ,(immich-gateway config))
                                              (ip_range . ,(string-append (immich-address config) "/32"))))))))))))
        (secrets . ((db-password . ((file . "/run/immich/db-password"))))))))))

(define (immich-prepare-program config)
  (program-file
   "immich-prepare"
   (with-imported-modules '((guix build utils) (guix build syscalls))
     #~(begin
         (use-modules (guix build utils) (guix build syscalls)
                      (ice-9 format)
                      (rnrs io ports) (rnrs bytevectors) (srfi srfi-1))
         (define data #$(immich-data-directory config))
         (define media #$(immich-media-directory config))
         (define external-secret #$(immich-password-file config))
         (define password-file (or external-secret (string-append data "/db-password")))
         ;; Check actual mounts on EVERY start, even if the readiness service
         ;; remains marked running after somebody manually unmounted storage.
         (define current-mounts (mounts))
         (define (mounted? path type source)
           (any (lambda (m)
                  (and (string=? path (mount-point m))
                       (string=? type (mount-type m))
                       (or (not source) (string=? source (mount-source m)))))
                current-mounts))
         (unless (and (mounted? "/data" "btrfs" #f)
                      (mounted? #$(immich-archive-mount config) "zfs"
                                #$(immich-archive-dataset config)))
           (error "Immich storage mounts are missing; refusing to create directories"))
         (unless (file-exists? #$(string-append "/sys/class/net/" (immich-parent-interface config)))
           (error "Immich macvlan parent interface is missing"))
         (umask #o077)
         (mkdir-p data)
         (chmod data #o700)
         (for-each mkdir-p (list media (string-append data "/postgres")
                                (string-append data "/model-cache")))
         ;; Containers may drop privileges; the parent /data/immich stays 0700.
         (chmod (string-append data "/model-cache") #o755)
         (unless (file-exists? password-file)
           (when (or external-secret
                     (file-exists? (string-append data "/postgres/PG_VERSION")))
             (error "Database password file missing; refusing to invent a replacement"))
           (let ((bytes (call-with-input-file "/dev/urandom"
                          (lambda (p) (get-bytevector-n p 32)) #:binary #t)))
             (unless (and (bytevector? bytes) (= 32 (bytevector-length bytes)))
               (error "Could not read enough entropy for database password"))
             (call-with-output-file (string-append password-file ".new")
               (lambda (p)
                 (for-each (lambda (b) (format p "~2,'0x" b))
                           (bytevector->u8-list bytes))
                 (newline p)))
             (chmod (string-append password-file ".new") #o600)
             (rename-file (string-append password-file ".new") password-file)))
         (when (zero? (stat:size (stat password-file)))
           (error "Database password file is empty"))
         ;; A runtime copy works with SOPS symlink swaps; force-recreate below
         ;; remounts the new inode.  Readable inside consumers, inaccessible
         ;; to other host users because /run/immich is root-only.
         (mkdir-p "/run/immich")
         (chmod "/run/immich" #o700)
         (copy-file password-file "/run/immich/db-password.new")
         (chmod "/run/immich/db-password.new" #o444)
         (rename-file "/run/immich/db-password.new" "/run/immich/db-password")))))

(define (immich-command config)
  (program-file
   "immich-compose"
   #~(begin
       (setenv "DOCKER_HOST" "unix:///var/run/docker.sock")
       (apply execl #$(file-append docker-full "/bin/docker")
              "docker" "compose" "--project-name" "immich"
              "--file" #$(immich-compose-file config)
              (cdr (command-line))))))

(define (immich-shepherd-services config)
  (let ((command (immich-command config)))
    (list
     (shepherd-service
      (provision '(immich))
      (requirement (append '(dockerd) (immich-requirements config)
                           (immich-secret-requirements config)))
      (documentation "Run Immich after storage and secrets are ready.")
      (start
       #~(lambda _
           (invoke #$(immich-prepare-program config))
           ;; Recreate the whole group so all containers join the current
           ;; anchor namespace and newly decrypted secret mounts.
           (catch #t
             (lambda ()
               (invoke #$command "up" "-d" "--force-recreate"
                       "--wait" "--wait-timeout" "300")
               #t)
             (lambda args
               ;; A failed start must not leave a partially running stack.
               (system* #$command "stop" "--timeout" "60")
               (apply throw args)))))
      (stop #~(lambda _ (invoke #$command "stop" "--timeout" "60") #f))
      (actions (list (shepherd-configuration-action (immich-compose-file config))))))))

(define immich-service-type
  (service-type
   (name 'immich)
   (extensions
    (list (service-extension shepherd-root-service-type immich-shepherd-services)
          (service-extension etc-service-type
                             (lambda (config)
                               `(("immich/compose.json" ,(immich-compose-file config))
                                 ("immich/compose" ,(immich-command config)))))))
   (default-value (immich-configuration))
   (description "Immich Compose stack with macvlan, guarded storage and runtime secrets.")))
