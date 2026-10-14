(define-module (uraj services paseo-relay)
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:use-module (json)
  #:use-module (gnu packages base)
  #:use-module (uraj packages docker)
  #:use-module (uraj services logs)
  #:export (paseo-relay-configuration paseo-relay-service-type
            paseo-relay-commit paseo-relay-compose-file paseo-relay-command))

(define-record-type* <paseo-relay-configuration>
  paseo-relay-configuration make-paseo-relay-configuration paseo-relay-configuration?
  ;; Full commit; `herd restart paseo-relay COMMIT' builds and runs another.
  (commit paseo-relay-commit (default "3fc41c96c8c63f3a7109e832899cc57d473c4531"))
  (network paseo-relay-network (default "docker_lan"))
  (address paseo-relay-address (default "172.31.0.8")))

(define (paseo-relay-compose-file config)
  ;; The start action sets the commit; manual Compose calls fall back.
  (define commit
    (string-append "${PASEO_RELAY_COMMIT:-" (paseo-relay-commit config) "}"))
  (plain-file
   "paseo-relay-compose.json"
   (scm->json-string
    `((name . "paseo-relay")
      (services .
       ((relay .
         ((image . ,(string-append "paseo-relay:" commit))
          (build . ((context . ,(string-append "https://github.com/getpaseo/paseo-relay.git#"
                                              commit))
                    ;; Storie deliberately disables the default Docker bridge.
                    (network . "host")))
          (restart . "on-failure")
          ,(compose-logging "paseo-relay")
          ;; Probe HTTP readiness using the release's own Erlang runtime;
          ;; upstream's slim runtime image has neither curl nor wget.
          (healthcheck .
           ((test . #("CMD" "/app/bin/paseo_relay" "rpc"
                      "{:ok, s} = :gen_tcp.connect(~c\"127.0.0.1\", 4000, [:binary, active: false, packet: :line], 2000); :ok = :gen_tcp.send(s, \"GET /ready HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n\"); result = :gen_tcp.recv(s, 0, 2000); :gen_tcp.close(s); case result do {:ok, \"HTTP/1.1 200 \" <> _} -> :ok; _ -> raise \"relay not ready\" end"))
            (interval . "30s") (timeout . "10s") (start_period . "20s") (retries . 3)))
          (environment . ((PASEO_RELAY_HOST . "0.0.0.0")
                          (PASEO_RELAY_PORT . "4000")))
          (networks . ((lan . ((ipv4_address . ,(paseo-relay-address config))))))))))
      (networks . ((lan . ((external . #t) (name . ,(paseo-relay-network config))))))))))

(define (paseo-relay-command config)
  (program-file
   "paseo-relay-compose"
   #~(begin
       (setenv "DOCKER_HOST" "unix:///var/run/docker.sock")
       (apply execl #$(file-append docker-full "/bin/docker")
              "docker" "compose" "--project-name" "paseo-relay"
              "--file" #$(paseo-relay-compose-file config)
              (cdr (command-line))))))

(define (paseo-relay-services config)
  (let ((command (paseo-relay-command config)))
    (list
     (shepherd-service
      (provision '(paseo-relay))
      ;; The container logs to syslog and cannot start without it.
      (requirement '(docker-lan syslogd))
      (documentation "Run the official Paseo relay on its own LAN address.")
      ;; Compose builds missing images from the pinned context.  An existing
      ;; commit-tagged image is reused; do not force --build on every boot.
      ;; --pull never applies to the service image, not build dependencies.
      ;; A commit argument lasts until the next plain (re)start, such as after
      ;; a reboot or a deployment.  The running value names the commit.
      (start #~(lambda* (#:optional (commit #$(paseo-relay-commit config)))
                 (unless (and (= 40 (string-length commit))
                              (string-every (string->char-set "0123456789abcdef")
                                            commit))
                   (error "paseo-relay needs a full lowercase commit" commit))
                 (catch #t
                   (lambda ()
                     (invoke #$(file-append coreutils "/bin/env")
                             (string-append "PASEO_RELAY_COMMIT=" commit)
                             #$command "up" "-d" "--pull" "never"
                             "--force-recreate" "--wait" "--wait-timeout" "60")
                     commit)
                   (lambda args
                     (system* #$command "stop" "--timeout" "30")
                     (apply throw args)))))
      (stop #~(lambda _ (invoke #$command "stop" "--timeout" "30") #f))
      (actions (list (shepherd-configuration-action (paseo-relay-compose-file config))))))))

(define paseo-relay-service-type
  (service-type
   (name 'paseo-relay)
   (extensions
    (list (service-extension shepherd-root-service-type paseo-relay-services)
          (service-extension service-log-service-type
            (lambda (config)
              (list (service-log (name "paseo-relay") (containers? #t)))))
          (service-extension etc-service-type
            (lambda (config)
              `(("paseo-relay/compose.json" ,(paseo-relay-compose-file config))
                ("paseo-relay/compose" ,(paseo-relay-command config)))))))
   (default-value (paseo-relay-configuration))
   (description "Official Paseo relay, built from a pinned upstream Dockerfile.")))
