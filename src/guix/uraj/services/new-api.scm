;;; new-api LLM gateway with Claude Code trajectory capture, on one macvlan
;;; address.  The image is the official release plus the traj_record plugin,
;;; built elsewhere with podman and loaded into Docker (see docs/new-api.org).
(define-module (uraj services new-api)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:use-module (json)
  #:use-module (uraj packages docker)
  #:export (new-api-configuration new-api-service-type
            new-api-compose-file new-api-prepare-program))

(define-record-type* <new-api-configuration>
  new-api-configuration make-new-api-configuration new-api-configuration?
  ;; Locally built, never pulled: a missing image fails startup visibly.
  (image new-api-image)
  ;; Database, application data and generated secrets (NVMe Btrfs @data).
  (data-directory new-api-data-directory (default "/data/new-api"))
  ;; Trajectory JSONL; low value, so it lives on the single-disk pool.
  (traj-directory new-api-traj-directory (default "/media-data/new-api/traj-records"))
  (traj-dataset new-api-traj-dataset (default "media-data"))
  (traj-mount new-api-traj-mount (default "/media-data"))
  (network new-api-network (default "docker_lan"))
  (address new-api-address (default "172.31.0.9"))
  (requirements new-api-requirements
                (default '(docker-lan zfs-data-ready file-system-/data))))

(define (bind source target)
  `((type . "bind") (source . ,source) (target . ,target)
    (bind . ((create_host_path . #f)))))

(define (new-api-compose-file config)
  ;; Follows upstream's docker-compose.yml (Postgres + Redis), but every
  ;; container shares the anchor's namespace and the databases listen only on
  ;; loopback.  on-failure restarts crashes without resurrecting containers
  ;; at daemon startup: Shepherd checks mounts and secrets first.
  (let* ((data (new-api-data-directory config))
         (common '((network_mode . "service:network") (restart . "on-failure")))
         (network-dependency '((network . ((condition . "service_started"))))))
    (plain-file
     "new-api-compose.json"
     (scm->json-string
      `((name . "new-api")
        (services .
         ((network .
           ((image . "registry.k8s.io/pause:3.10@sha256:ee6521f290b2168b6e0935a181d4cff9be1ac3f505666ef0e3c98fae8199917a")
            (restart . "on-failure")
            (networks . ((lan . ((ipv4_address . ,(new-api-address config))))))))
          (new-api .
           (,@common
            (image . ,(new-api-image config))
            ;; The image only reads credentials from the environment.  Build
            ;; them from secret files at startup so the Compose file (in the
            ;; store) never contains them.  $$ is Compose's escape for $.
            (entrypoint . #("/bin/sh" "-c"
                            "SQL_DSN=\"postgresql://newapi:$$(cat /run/secrets/db-password)@127.0.0.1:5432/new-api\" SESSION_SECRET=\"$$(cat /run/secrets/session-secret)\" exec /new-api --log-dir /app/logs"))
            (environment . ((TZ . "Asia/Shanghai")
                            (REDIS_CONN_STRING . "redis://127.0.0.1:6379")
                            (ERROR_LOG_ENABLED . "true")
                            (BATCH_UPDATE_ENABLED . "true")
                            (NODE_NAME . "storie")
                            ;; Plain HTTP on the LAN; clients connect directly.
                            (SESSION_COOKIE_SECURE . "false")
                            (TRUSTED_PROXIES . "none")
                            (TRAJ_RECORD_ENABLED . "true")
                            (TRAJ_RECORD_DIR . "/traj-records")
                            (TRAJ_RECORD_INSTANCE . "storie")))
            (secrets . #("db-password" "session-secret"))
            (volumes . ,(vector (bind (string-append data "/app") "/data")
                                (bind (string-append data "/logs") "/app/logs")
                                (bind (new-api-traj-directory config) "/traj-records")))
            (depends_on . ((network . ((condition . "service_started")))
                           (database . ((condition . "service_healthy")))
                           (redis . ((condition . "service_healthy")))))
            (healthcheck .
             ((test . #("CMD-SHELL" "wget -q -O - http://127.0.0.1:3000/api/status | grep -q '\"success\":true'"))
              (interval . "30s") (timeout . "10s") (start_period . "60s") (retries . 3)))))
          (redis .
           (,@common
            (image . "docker.io/valkey/valkey:9@sha256:70739f85ad2ee01a726a965584a0f94895f01b0c60b3cc8b0aeef11eaa6888cf")
            (command . #("valkey-server" "--bind" "127.0.0.1"))
            (depends_on . ,network-dependency)
            (healthcheck . ((test . #("CMD" "redis-cli" "ping"))
                            (interval . "10s") (retries . 5)))))
          (database .
           (,@common
            (image . "docker.io/library/postgres:15@sha256:724292da1f2e50bdccfc3302ce75bbba7f4a6076701b588cc795fcac65683550")
            (command . #("postgres" "-c" "listen_addresses=127.0.0.1"))
            (environment . ((POSTGRES_PASSWORD_FILE . "/run/secrets/db-password")
                            (POSTGRES_USER . "newapi")
                            (POSTGRES_DB . "new-api")))
            (secrets . #("db-password"))
            (volumes . ,(vector (bind (string-append data "/postgres")
                                      "/var/lib/postgresql/data")))
            (depends_on . ,network-dependency)
            (healthcheck .
             ((test . #("CMD" "pg_isready" "-h" "127.0.0.1" "-U" "newapi" "-d" "new-api"))
              (interval . "10s") (retries . 10)))))))
        (networks .
         ((lan . ((external . #t) (name . ,(new-api-network config))))))
        (secrets .
         ((db-password . ((file . "/run/new-api/db-password")))
          (session-secret . ((file . "/run/new-api/session-secret"))))))))))

(define (new-api-prepare-program config)
  (program-file
   "new-api-prepare"
   (with-imported-modules '((guix build utils) (guix build syscalls))
     #~(begin
         (use-modules (guix build utils) (guix build syscalls)
                      (ice-9 format)
                      (rnrs io ports) (rnrs bytevectors) (srfi srfi-1))
         (define data #$(new-api-data-directory config))
         (define secrets (string-append data "/secrets"))
         ;; Check actual mounts on EVERY start, so a missing pool can never
         ;; make Docker create the directories on the bare root filesystem.
         (define current-mounts (mounts))
         (define (mounted? path type source)
           (any (lambda (m)
                  (and (string=? path (mount-point m))
                       (string=? type (mount-type m))
                       (or (not source) (string=? source (mount-source m)))))
                current-mounts))
         (unless (and (mounted? "/data" "btrfs" #f)
                      (mounted? #$(new-api-traj-mount config) "zfs"
                                #$(new-api-traj-dataset config)))
           (error "new-api storage mounts are missing; refusing to create directories"))
         (umask #o077)
         (for-each mkdir-p
                   (list secrets #$(new-api-traj-directory config)
                         (string-append data "/app") (string-append data "/logs")
                         (string-append data "/postgres")))
         (chmod data #o700)
         (define (ensure-secret name may-generate?)
           (let ((file (string-append secrets "/" name)))
             (unless (file-exists? file)
               (unless may-generate?
                 (error "Secret missing while its data exists; refusing to invent a replacement" name))
               (let ((bytes (call-with-input-file "/dev/urandom"
                              (lambda (p) (get-bytevector-n p 32)) #:binary #t)))
                 (unless (and (bytevector? bytes) (= 32 (bytevector-length bytes)))
                   (error "Could not read enough entropy" name))
                 (call-with-output-file (string-append file ".new")
                   (lambda (p)
                     (for-each (lambda (b) (format p "~2,'0x" b))
                               (bytevector->u8-list bytes))))
                 (rename-file (string-append file ".new") file)))
             (when (zero? (stat:size (stat file)))
               (error "Secret file is empty" name))
             ;; Readable inside the containers; /run/new-api itself is root-only.
             (copy-file file (string-append "/run/new-api/" name ".new"))
             (chmod (string-append "/run/new-api/" name ".new") #o444)
             (rename-file (string-append "/run/new-api/" name ".new")
                          (string-append "/run/new-api/" name))))
         (mkdir-p "/run/new-api")
         (chmod "/run/new-api" #o700)
         ;; A new password would lock new-api out of an existing database.
         (ensure-secret "db-password"
                        (not (file-exists? (string-append data "/postgres/PG_VERSION"))))
         ;; Rotating the session secret only logs users out.
         (ensure-secret "session-secret" #t)))))

(define (new-api-command config)
  (program-file
   "new-api-compose"
   #~(begin
       (setenv "DOCKER_HOST" "unix:///var/run/docker.sock")
       (apply execl #$(file-append docker-full "/bin/docker")
              "docker" "compose" "--project-name" "new-api"
              "--file" #$(new-api-compose-file config)
              (cdr (command-line))))))

(define (new-api-shepherd-services config)
  (let ((command (new-api-command config)))
    (list
     (shepherd-service
      (provision '(new-api))
      (requirement (cons 'dockerd (new-api-requirements config)))
      (documentation "Run new-api after storage and the shared network are ready.")
      (start
       #~(lambda _
           (invoke #$(new-api-prepare-program config))
           (catch #t
             (lambda ()
               ;; The new-api image is never pulled; the databases and the
               ;; anchor are pulled once by digest.
               (invoke #$command "up" "-d" "--pull" "missing" "--force-recreate"
                       "--wait" "--wait-timeout" "300")
               #t)
             (lambda args
               (system* #$command "stop" "--timeout" "30")
               (apply throw args)))))
      (stop #~(lambda _ (invoke #$command "stop" "--timeout" "30") #f))
      (actions (list (shepherd-configuration-action (new-api-compose-file config))))))))

(define new-api-service-type
  (service-type
   (name 'new-api)
   (extensions
    (list (service-extension shepherd-root-service-type new-api-shepherd-services)
          (service-extension etc-service-type
                             (lambda (config)
                               `(("new-api/compose.json" ,(new-api-compose-file config))
                                 ("new-api/compose" ,(new-api-command config)))))))
   (description "new-api Compose stack with trajectory capture, on the shared macvlan LAN.")))
