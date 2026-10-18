;;; One Feishu bot, one Gateway, one agent; runtime credentials stay out of
;;; the store. See docs/openclaw.org for image preparation and activation.
(define-module (uraj services openclaw)
  #:use-module (gnu packages base)
  #:use-module (gnu packages guile)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:use-module (ice-9 regex)
  #:use-module (json)
  #:use-module (sops secrets)
  #:use-module (sops services sops)
  #:use-module (srfi srfi-1)
  #:use-module (uraj utils gexp)
  #:use-module (uraj packages docker)
  #:use-module (uraj services logs)
  #:export (openclaw-provider openclaw-configuration
            openclaw-service-type openclaw-config-file
            openclaw-compose-file openclaw-prepare-program openclaw-secrets))

(define-record-type* <openclaw-provider>
  openclaw-provider make-openclaw-provider openclaw-provider?
  (name openclaw-provider-name)
  (api openclaw-provider-api)
  ;; Anthropic's SDK appends /v1/messages; OpenAI APIs need a /v1 base.
  ;; #f selects the appropriate new-api URL for API.
  (base-url openclaw-provider-base-url (default #f))
  (models openclaw-provider-models))

(define (provider-url provider)
  (or (openclaw-provider-base-url provider)
      (if (equal? "anthropic-messages" (openclaw-provider-api provider))
          "http://172.31.0.9:3000" "http://172.31.0.9:3000/v1")))

(define-record-type* <openclaw-configuration>
  openclaw-configuration make-openclaw-configuration openclaw-configuration?
  ;; Include the Feishu plugin in this image. A digest is required for the
  ;; declared image; restart TAG is an explicit temporary exception.
  (image openclaw-image)
  ;; Used for restart TAG when IMAGE is a locally built sha256 image ID.
  (image-repository openclaw-image-repository (default "localhost/openclaw-feishu"))
  (secrets-file openclaw-secrets-file)
  (feishu-app-id openclaw-feishu-app-id)
  ;; Full provider/model reference, explicitly present in PROVIDERS.
  (model openclaw-model)
  ;; Each provider selects its own API; all use the same new-api token.
  (providers openclaw-providers)
  (data-directory openclaw-data-directory (default "/data/openclaw"))
  (network openclaw-network (default "static-agent")))

(define %secret-names '("feishu-app-secret" "new-api-token" "gateway-token"))

(define (validate-config config)
  (unless (string-match "^([A-Za-z0-9][A-Za-z0-9._:/-]*@)?sha256:[0-9a-f]{64}$"
                        (openclaw-image config))
    (error "OpenClaw declared image must be pinned by sha256 digest"))
  (unless (string-match "^[A-Za-z0-9][A-Za-z0-9._:/-]*$"
                        (openclaw-image-repository config))
    (error "Invalid OpenClaw image repository"))
  (unless (string-match "^cli_[A-Za-z0-9]+$" (openclaw-feishu-app-id config))
    (error "OpenClaw requires a Feishu App ID"))
  (let ((providers (openclaw-providers config)))
    (unless (and (list? providers) (pair? providers)
                 (every openclaw-provider? providers))
      (error "OpenClaw requires at least one provider"))
    (for-each
     (lambda (provider)
       (unless (and (string? (openclaw-provider-name provider))
                    (string-match "^[a-z][a-z0-9-]*$" (openclaw-provider-name provider)))
         (error "Invalid OpenClaw provider name"))
       (unless (member (openclaw-provider-api provider)
                       '("openai-completions" "openai-responses" "anthropic-messages"))
         (error "Unsupported OpenClaw provider API"))
       (unless (and (string? (provider-url provider))
                    (string-match "^https?://[^[:space:]]+$" (provider-url provider)))
         (error "OpenClaw provider base URL must use HTTP or HTTPS"))
       (unless (and (list? (openclaw-provider-models provider))
                    (pair? (openclaw-provider-models provider))
                    (every (lambda (model)
                             (and (string? model) (not (string-null? model))))
                           (openclaw-provider-models provider)))
         (error "OpenClaw provider needs a nonempty list of model IDs")))
     providers)
    (let ((names (map openclaw-provider-name providers)))
      (unless (= (length names) (length (delete-duplicates names)))
        (error "Duplicate OpenClaw provider name")))
    (unless (member (openclaw-model config)
                    (append-map
                     (lambda (provider)
                       (map (lambda (model)
                              (string-append (openclaw-provider-name provider) "/" model))
                            (openclaw-provider-models provider))) providers))
      (error "OpenClaw default must be a declared provider/model reference")))
  (unless (and (string-prefix? "/data/" (openclaw-data-directory config))
               (not (member ".." (string-split (openclaw-data-directory config) #\/))))
    (error "OpenClaw data must be below /data")))

(define (openclaw-secrets config)
  (map (lambda (name)
         (sops-secret
           (key (list "openclaw" name))
           (file (openclaw-secrets-file config))
           (user "root") (group "root") (permissions #o400)))
       %secret-names))

(define (secret-ref name)
  `((source . "file") (provider . ,name) (id . "value")))

(define (provider-config provider)
  (cons (openclaw-provider-name provider)
        `((baseUrl . ,(provider-url provider))
          (apiKey . ,(secret-ref "new-api-token"))
          (api . ,(openclaw-provider-api provider))
          (models . ,(list->vector
                      (map (lambda (model) `((id . ,model) (name . ,model)))
                           (delete-duplicates (openclaw-provider-models provider))))))))

(define (openclaw-config-file config)
  (validate-config config)
  (plain-file
   "openclaw.json"
   (scm->json-string
    `((gateway . ((mode . "local") (bind . "lan") (port . 18789)
                  (auth . ((mode . "token") (token . ,(secret-ref "gateway-token"))))
                  (controlUi . ((allowedOrigins . #("http://localhost:18789"
                                                    "http://127.0.0.1:18789"))))
                  (terminal . ((enabled . #f)))
                  (cliAgents . ((enabled . #f)))))
      (secrets .
       ((providers . ,(map (lambda (name)
                             (cons name `((source . "file") (mode . "singleValue")
                                          (path . ,(string-append "/run/secrets/" name)))))
                           %secret-names))))
      (models .
       ((mode . "replace")
        (catalogRefresh . ((enabled . #f)))
        (providers . ,(map provider-config (openclaw-providers config)))))
      (agents . ((defaults . ((workspace . "/workspace")
                             (model . ((primary . ,(openclaw-model config))))
                             (heartbeat . ((every . "0m")))))))
      ;; Ordinary channel replies do not need the model-facing message tool.
      ;; Start with text chat; enabling execution needs a separate design.
      (tools . ((deny . #("*"))))
      (browser . ((enabled . #f)))
      (cron . ((enabled . #f)))
      (session . ((dmScope . "per-channel-peer")))
      (channels .
       ((feishu .
         ((enabled . #t) (domain . "feishu") (connectionMode . "websocket")
          (defaultAccount . "main") (dmPolicy . "pairing")
          (groupPolicy . "disabled") (requireMention . #t)
          (configWrites . #f) (resolveSenderNames . #f)
          (typingIndicator . #f) (renderMode . "raw")
          (streaming . ((mode . "off")))
          (tools . ((doc . #f) (chat . #f) (wiki . #f) (drive . #f)
                    (perm . #f) (scopes . #f) (bitable . #f)))
          (accounts . ((main . ((appId . ,(openclaw-feishu-app-id config))
                                (appSecret . ,(secret-ref "feishu-app-secret"))))))))))
      (plugins . ((entries . ((feishu . ((enabled . #t)))))))
      (update . ((checkOnStart . #f) (auto . ((enabled . #f)))))))))

(define* (bind source target #:optional (read-only? #f))
  `((type . "bind") (source . ,source) (target . ,target)
    (read_only . ,read-only?) (bind . ((create_host_path . #f)))))

(define (openclaw-compose-file config)
  (validate-config config)
  (plain-file
   "openclaw-compose.json"
   (scm->json-string
    `((name . "openclaw")
      (services .
       ((gateway .
         ((image . ,(string-append "${OPENCLAW_IMAGE:-" (openclaw-image config) "}"))
          (pull_policy . "never") (restart . "on-failure")
          (user . "1000:1000") (read_only . #t)
          (cap_drop . #("ALL")) (security_opt . #("no-new-privileges:true"))
          (pids_limit . 512) (mem_limit . "4g")
          (tmpfs . #("/tmp:rw,nosuid,nodev,size=512m,mode=1777"
                     ;; OpenClaw's secure-temp resolver may fall back here.
                     "/home/node/.cache:rw,nosuid,nodev,size=128m,uid=1000,gid=1000,mode=0700"))
          ,(compose-logging "openclaw")
          (environment . ((HOME . "/home/node")
                          (OPENCLAW_STATE_DIR . "/home/node/.openclaw")
                          (OPENCLAW_CONFIG_PATH . "/etc/openclaw/openclaw.json")
                          ;; Doctor must report edits to our declarative config,
                          ;; while still repairing writable runtime state.
                          (OPENCLAW_CONFIG_READONLY . "1")
                          ;; Implemented by our version-pinned Feishu patch.
                          (OPENCLAW_FEISHU_RECEIPT_REACTION . "GET")
                          (OPENCLAW_DISABLE_BONJOUR . "1")))
          (command . #("node" "openclaw.mjs" "gateway"))
          (volumes .
           ,(list->vector
             (append
              (list (bind (string-append (openclaw-data-directory config) "/home")
                          "/home/node")
                    (bind (string-append (openclaw-data-directory config) "/workspaces/main")
                          "/workspace")
                    (bind "/etc/openclaw/openclaw.json" "/etc/openclaw/openclaw.json" #t))
              (map (lambda (name) (bind (string-append "/run/openclaw/" name)
                                        (string-append "/run/secrets/" name) #t))
                   %secret-names))))
          ;; The startup program adds explicit DNS from the firewall snapshot.
          (networks . #("restricted"))
          (healthcheck .
           ((test . #("CMD" "node" "-e"
                      "fetch('http://127.0.0.1:18789/startupz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"))
            (interval . "30s") (timeout . "10s")
            (start_period . "60s") (retries . 5)))))))
      (networks . ((restricted . ((external . #t) (name . ,(openclaw-network config))))))))))

(define (openclaw-prepare-program config)
  (validate-config config)
  (program-file
   "openclaw-prepare"
   (with-extensions (list guile-json-4)
     (with-uraj-modules '((uraj build openclaw))
       #~(begin
           (use-modules (uraj build openclaw))
           (prepare-openclaw
            #$(openclaw-data-directory config)
            (list #$@(map (lambda (name secret)
                            #~(cons #$name #$(sops-secret->secret-file secret)))
                          %secret-names (openclaw-secrets config)))))))))

(define (openclaw-command config)
  (program-file
   "openclaw-compose"
   #~(begin
       (setenv "DOCKER_HOST" "unix:///var/run/docker.sock")
       (apply execl #$(file-append docker-full "/bin/docker") "docker" "compose"
              "--project-name" "openclaw"
              "--file" #$(openclaw-compose-file config)
              "--file" "/run/openclaw/compose-dns.json"
              (cdr (command-line))))))

(define (openclaw-shepherd-services config)
  (let ((command (openclaw-command config)))
    (list
     (shepherd-service
       (provision '(openclaw))
       (requirement '(dockerd restricted-network sops-secrets syslogd file-system-/data))
       (documentation "Run the private Feishu OpenClaw Gateway.")
       ;; Hot upgrades evaluate this closure in the existing Shepherd process.
       ;; Keep its dependencies in Guile; preparation has its own module paths.
       (modules (append '((ice-9 popen) (ice-9 rdelim) (ice-9 regex))
                        %default-modules))
       (start
        #~(lambda* (#:optional tag)
            (define pinned #$(openclaw-image config))
            (define base (car (string-split pinned #\@)))
            (define colon (string-rindex base #\:))
            (define slash (or (string-rindex base #\/) -1))
            (define repository
              (if (string-prefix? "sha256:" pinned)
                  #$(openclaw-image-repository config)
                  (if (and colon (> colon slash))
                      (substring base 0 colon) base)))
            (when tag
              (unless (and (string? tag)
                           (string-match "^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$" tag))
                (error "Invalid OpenClaw image tag" tag)))
            (let* ((image (if tag (string-append repository ":" tag) pinned))
                   ;; Resolve the local image once. Run its immutable ID so
                   ;; a tag update between inspect and up cannot change it.
                   (port (open-pipe* OPEN_READ #$(file-append docker-full "/bin/docker")
                                     "--host" "unix:///var/run/docker.sock"
                                     "image" "inspect" "--format" "{{.Id}}" image))
                   (id (read-line port))
                   (status (close-pipe port)))
              (unless (and (zero? status) (string? id)
                           (string-prefix? "sha256:" id))
                (error "OpenClaw image must already exist locally" image))
              (invoke #$(openclaw-prepare-program config))
              (catch #t
                (lambda ()
                  ;; Validate with the chosen image's own plugin schemas,
                  ;; before starting the long-lived Gateway.
                  (invoke #$(file-append coreutils "/bin/env")
                          (string-append "OPENCLAW_IMAGE=" id)
                          #$command "run" "--rm" "--no-deps" "--pull" "never"
                          "gateway" "node" "openclaw.mjs" "config" "validate")
                  (invoke #$(file-append coreutils "/bin/env")
                          (string-append "OPENCLAW_IMAGE=" id)
                          #$command "up" "-d" "--pull" "never" "--no-build"
                          "--force-recreate" "--wait" "--wait-timeout" "180")
                  (list image id))
                (lambda args
                  (system* #$command "stop" "--timeout" "30")
                  (apply throw args))))))
       (stop #~(lambda _ (invoke #$command "stop" "--timeout" "30") #f))
       (actions (list (shepherd-configuration-action (openclaw-compose-file config))))))))

(define openclaw-service-type
  (service-type
    (name 'openclaw)
    (extensions
     (list (service-extension shepherd-root-service-type openclaw-shepherd-services)
           (service-extension sops-secrets-service-type openclaw-secrets)
           (service-extension service-log-service-type
             (lambda (_) (list (service-log (name "openclaw") (containers? #t)))))
           (service-extension etc-service-type
             (lambda (config)
               `(("openclaw/openclaw.json" ,(openclaw-config-file config))
                 ("openclaw/compose.json" ,(openclaw-compose-file config))
                 ("openclaw/compose" ,(openclaw-command config)))))))
    (description "Administrator-paired OpenClaw Gateway on the restricted workload network.")))
