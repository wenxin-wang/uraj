;;; Gateway with checked runtime configuration and a nested Podman engine for
;;; sandboxed tools; credentials stay out of the store and the engine.  See
;;; docs/openclaw.org for image preparation and activation.
(define-module (uraj services openclaw)
  #:use-module (gnu packages acl)
  #:use-module (gnu packages admin)
  #:use-module (gnu packages base)
  #:use-module (gnu packages guile)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (gnu system shadow)
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
  (models openclaw-provider-models)
  ;; Explicit capabilities for custom models absent from the built-in catalog.
  ;; Responses uses developer instructions for reasoning models.
  (reasoning-models openclaw-provider-reasoning-models (default '())))

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
  (image-repository openclaw-image-repository (default "localhost/openclaw-gateway"))
  (secrets-file openclaw-secrets-file)
  ;; SOPS: openclaw.feishu-app-id and a JSON array in openclaw.command-owners.
  (identity-file openclaw-identity-file (default #f))
  (feishu-app-id openclaw-feishu-app-id (default #f))
  ;; Full provider/model reference, explicitly present in PROVIDERS.
  (model openclaw-model)
  ;; Each provider selects its own API; all use the same new-api token.
  (providers openclaw-providers)
  ;; Alist of declared provider/model references to slash-command aliases.
  (model-aliases openclaw-model-aliases (default '()))
  ;; Engine and sandbox images are local image IDs; see docs/openclaw.org.
  (engine-image openclaw-engine-image)
  (sandbox-image openclaw-sandbox-image)
  ;; Shared by the Gateway, the engine's Podman user and sandboxes; the
  ;; engine image must be built with the same IDs.
  (uid openclaw-uid (default 2010))
  (gid openclaw-gid (default 2010))
  (data-directory openclaw-data-directory (default "/data/openclaw"))
  (network openclaw-network (default "static-agent"))
  (sandbox-network openclaw-sandbox-network (default "sandboxed-agents")))

;; The engine serves Podman here; only the Gateway mounts it.
(define %engine-runtime "/run/openclaw-engine")
(define %engine-socket (string-append "unix://" %engine-runtime "/podman.sock"))

(define (data-path config . parts)
  (string-join (cons (openclaw-data-directory config) parts) "/"))

;; State subdirectories OpenClaw binds read-only into sandboxes: skill copies
;; for rw workspaces and subagent attachments.  Never credentials.
(define %sandbox-state-mounts
  '(".openclaw/sandbox/skills-workspaces" ".openclaw/attachments/subagents"))

(define (owner config)
  (format #f "~a:~a" (openclaw-uid config) (openclaw-gid config)))

(define %secret-names '("feishu-app-secret" "new-api-token" "gateway-token"))

(define (validate-config config)
  (unless (string-match "^([A-Za-z0-9][A-Za-z0-9._:/-]*@)?sha256:[0-9a-f]{64}$"
                        (openclaw-image config))
    (error "OpenClaw declared image must be pinned by sha256 digest"))
  (unless (string-match "^[A-Za-z0-9][A-Za-z0-9._:/-]*$"
                        (openclaw-image-repository config))
    (error "Invalid OpenClaw image repository"))
  (for-each (lambda (image)
              (unless (string-match "^sha256:[0-9a-f]{64}$" image)
                (error "OpenClaw engine and sandbox images must be local image IDs"
                       image)))
            (list (openclaw-engine-image config) (openclaw-sandbox-image config)))
  ;; Podman rejects UID or GID 0 for rootless keep-id sandboxes.
  (unless (and (every (lambda (id) (and (exact-integer? id) (< 0 id 65536)))
                      (list (openclaw-uid config) (openclaw-gid config))))
    (error "OpenClaw needs a nonzero dedicated UID and GID"))
  (unless (if (openclaw-identity-file config)
              (not (openclaw-feishu-app-id config))
              (and (string? (openclaw-feishu-app-id config))
                   (string-match "^cli_[A-Za-z0-9]+$" (openclaw-feishu-app-id config))))
    (error "OpenClaw requires either an identity file or a literal Feishu App ID"))
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
         (error "OpenClaw provider needs a nonempty list of model IDs"))
       (unless (and (list? (openclaw-provider-reasoning-models provider))
                    (every (lambda (model)
                             (member model (openclaw-provider-models provider)))
                           (openclaw-provider-reasoning-models provider)))
         (error "OpenClaw reasoning models must be declared provider models")))
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
  (let ((aliases (openclaw-model-aliases config))
        (models (append-map
                 (lambda (provider)
                   (map (lambda (model)
                          (string-append (openclaw-provider-name provider) "/" model))
                        (openclaw-provider-models provider)))
                 (openclaw-providers config))))
    (unless (and (list? aliases)
                 (every (lambda (entry)
                          (and (pair? entry) (member (car entry) models)
                               (string? (cdr entry))
                               (string-match "^[a-z][a-z0-9-]*$" (cdr entry))))
                        aliases))
      (error "OpenClaw aliases need declared models and lowercase command names"))
    (unless (and (= (length aliases) (length (delete-duplicates (map car aliases))))
                 (= (length aliases) (length (delete-duplicates (map cdr aliases)))))
      (error "Duplicate OpenClaw model alias or reference")))
  (unless (and (string-prefix? "/data/" (openclaw-data-directory config))
               (not (member ".." (string-split (openclaw-data-directory config) #\/))))
    (error "OpenClaw data must be below /data")))

(define (secret-names config)
  (append %secret-names
          (if (openclaw-identity-file config) '("command-owners" "feishu-app-id") '())))

(define (openclaw-secrets config)
  (map (lambda (name)
         (sops-secret
           (key (list "openclaw" name))
           (file (if (member name '("command-owners" "feishu-app-id"))
                     (openclaw-identity-file config)
                     (openclaw-secrets-file config)))
           (user "root") (group "root") (permissions #o400)))
       (secret-names config)))

(define (secret-ref name)
  `((source . "file") (provider . ,name) (id . "value")))

(define (provider-config provider)
  (cons (openclaw-provider-name provider)
        `((baseUrl . ,(provider-url provider))
          (apiKey . ,(secret-ref "new-api-token"))
          (api . ,(openclaw-provider-api provider))
          (models . ,(list->vector
                      (map (lambda (model)
                             (append `((id . ,model) (name . ,model))
                                     (if (member model
                                                 (openclaw-provider-reasoning-models provider))
                                         '((reasoning . #t)) '())))
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
      (agents . ((defaults . ((workspace . ,(data-path config "workspaces/main"))
                             (model . ((primary . ,(openclaw-model config))))
                             (models . ,(if (null? (openclaw-model-aliases config))
                                            '()
                                            (map (lambda (entry)
                                                   (cons (car entry)
                                                         `((alias . ,(cdr entry)))))
                                                 (openclaw-model-aliases config))))
                             (heartbeat . ((every . "0m")))
                             ;; Every session runs tools in the engine; the
                             ;; Podman backend needs host paths, see
                             ;; docs/openclaw.org.
                             (sandbox
                              . ((mode . "all") (backend . "podman")
                                 (scope . "agent") (workspaceAccess . "rw")
                                 (workspaceRoot
                                  . ,(data-path config "workspaces/.sandboxes"))
                                 (docker
                                  . ((image . ,(string-drop
                                                (openclaw-sandbox-image config) 7))
                                     (network . "pasta") (readOnlyRoot . #t)
                                     (capDrop . #("ALL"))
                                     (user . ,(owner config))))))))
                 (ownership . "explicit")
                 (entries . ((main . ((workspace . ,(data-path config "workspaces/main"))
                                      (agentDir
                                       . ,(data-path config
                                                     "home/.openclaw/agents/main/agent"))))
                             (household-shared
                              . ((name . "家庭助手")
                                 (workspace . ,(data-path config "workspaces/household-shared"))
                                 (agentDir . ,(data-path config
                                                          "home/.openclaw/agents/household-shared/agent"))))))))
      (bindings . #(((agentId . "household-shared")
                     (match . ((channel . "feishu") (accountId . "main"))))))
      (tools . ((allow . #("read" "write" "edit" "apply_patch" "exec" "process"
                           "openclaw_config_set"))
                (fs . ((workspaceOnly . #t)))
                ;; No fallback to the Gateway, which holds the credentials.
                (exec . ((host . "sandbox") (mode . "full")
                         (applyPatch . ((enabled . #t)
                                       (workspaceOnly . #t)))))
                (elevated . ((enabled . #f)))
                ;; The checked configuration tool runs in the Gateway.
                (sandbox . ((tools . ((alsoAllow . #("openclaw_config_set"))))))))
      (browser . ((enabled . #f)))
      (cron . ((enabled . #f)))
      (session . ((dmScope . "per-channel-peer")))
      (channels .
       ((feishu .
         ((enabled . #t) (domain . "feishu") (connectionMode . "websocket")
          (defaultAccount . "main") (dmPolicy . "pairing")
          (groupPolicy . "open") (requireMention . #t)
          (groupSessionScope . "group_topic") (replyInThread . "enabled")
          (configWrites . #t) (resolveSenderNames . #f)
          (typingIndicator . #t) (renderMode . "raw")
          (streaming . ((mode . "off")))
          (tools . ((doc . #f) (chat . #f) (wiki . #f) (drive . #f)
                    (perm . #f) (scopes . #f) (bitable . #f)))
          (accounts . ((main . (,@(if (openclaw-feishu-app-id config)
                                     `((appId . ,(openclaw-feishu-app-id config))) '())
                                (appSecret . ,(secret-ref "feishu-app-secret"))))))))))
      (plugins . ((load . ((paths . #("/etc/openclaw/config-plugin"))))
                  (entries . ((feishu . ((enabled . #t)))
                              (uraj-config-policy
                               . ((enabled . #t)
                                  (hooks . ((allowConversationAccess . #t)))
                                  (llm . ((allowAgentIdOverride . #t)))))))))
      (update . ((checkOnStart . #f) (auto . ((enabled . #f)))))))))

(define* (bind source target #:optional (read-only? #f))
  `((type . "bind") (source . ,source) (target . ,target)
    (read_only . ,read-only?) (bind . ((create_host_path . #f)))))

(define (openclaw-compose-file config)
  (validate-config config)
  (let ((home (data-path config "home"))
        (workspaces (data-path config "workspaces"))
        (uid (openclaw-uid config)) (gid (openclaw-gid config)))
    (plain-file
     "openclaw-compose.json"
     (scm->json-string
      `((name . "openclaw")
        (services .
         ((gateway .
           ((image . ,(string-append "${OPENCLAW_IMAGE:-" (openclaw-image config) "}"))
            (pull_policy . "never") (restart . "on-failure")
            (user . ,(owner config)) (read_only . #t)
            (cap_drop . #("ALL")) (security_opt . #("no-new-privileges:true"))
            (pids_limit . 512) (mem_limit . "4g")
            (tmpfs . #("/tmp:rw,nosuid,nodev,size=512m,mode=1777"
                       ;; OpenClaw's secure-temp resolver may fall back here.
                       ,(format #f "~a/.cache:rw,nosuid,nodev,size=128m,uid=~a,gid=~a,mode=0700"
                                home uid gid)))
            ,(compose-logging "openclaw")
            ;; The Podman backend binds Gateway paths into sandboxes, so
            ;; state and workspaces keep their host paths.
            (environment . ((HOME . ,home)
                            (OPENCLAW_STATE_DIR . ,(string-append home "/.openclaw"))
                            (OPENCLAW_CONFIG_PATH
                             . ,(string-append home "/.openclaw/openclaw.json"))
                            ,@(if (openclaw-identity-file config)
                                  '((OPENCLAW_COMMAND_OWNERS_FILE
                                     . "/run/secrets/command-owners")
                                    (OPENCLAW_FEISHU_APP_ID_FILE
                                     . "/run/secrets/feishu-app-id")) '())
                            (OPENCLAW_DISABLE_BONJOUR . "1")
                            (CONTAINER_HOST . ,%engine-socket)))
            (command . #("node" "openclaw.mjs" "gateway"))
            (depends_on . ((engine . ((condition . "service_healthy")))))
            (volumes .
             ,(list->vector
               (append
                (list (bind home home)
                      (bind workspaces workspaces)
                      (bind %engine-runtime %engine-runtime)
                      (bind "/etc/openclaw/base.json" "/etc/openclaw/base.json" #t)
                      (bind "/etc/openclaw/config.mjs" "/etc/openclaw/config.mjs" #t)
                      (bind "/etc/openclaw/config-policy.mjs" "/etc/openclaw/config-policy.mjs" #t)
                      (bind "/etc/openclaw/config-plugin" "/etc/openclaw/config-plugin" #t))
                (map (lambda (name) (bind (string-append "/run/openclaw/" name)
                                          (string-append "/run/secrets/" name) #t))
                     (secret-names config)))))
            ;; The startup program adds explicit DNS from the firewall snapshot.
            (networks . #("restricted"))
            (healthcheck .
             ((test . #("CMD" "node" "-e"
                        "fetch('http://127.0.0.1:18789/startupz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"))
              (interval . "30s") (timeout . "10s")
              (start_period . "60s") (retries . 5)))))
          ;; Rootless Podman nested in Docker; see docs/openclaw.org for why
          ;; each relaxation is needed.  Only selected sandbox state is shared.
          (engine .
           ((image . ,(openclaw-engine-image config))
            (pull_policy . "never") (restart . "on-failure")
            (user . ,(owner config))
            (cap_drop . #("ALL")) (cap_add . #("SETUID" "SETGID"))
            (security_opt . #("seccomp=/etc/openclaw/engine-seccomp.json"
                              "systempaths=unconfined"))
            (devices . #("/dev/fuse" "/dev/net/tun"))
            ;; Shared by all sandboxes; Docker mounts cgroups read-only.
            (pids_limit . 4096) (mem_limit . "8g")
            (tmpfs . #(,(format #f "/run/user/~a:rw,nosuid,nodev,size=256m,uid=~a,gid=~a,mode=0700"
                                uid uid gid)))
            ,(compose-logging "openclaw")
            (volumes .
             ,(list->vector
               (append
                (list (bind workspaces workspaces)
                      (bind (data-path config "engine")
                            "/home/podman/.local/share/containers")
                      (bind %engine-runtime %engine-runtime))
                (map (lambda (part)
                       (let ((path (string-append home "/" part)))
                         (bind path path #t)))
                     %sandbox-state-mounts))))
            (networks . #("sandbox"))
            (healthcheck .
             ((test . #("CMD" "podman" "--remote" "--url" ,%engine-socket
                        "info" "--format" "{{.Host.Security.Rootless}}"))
              (interval . "30s") (timeout . "10s")
              (start_period . "30s") (retries . 5)))))))
        (networks .
         ((restricted . ((external . #t) (name . ,(openclaw-network config))))
          (sandbox . ((external . #t)
                      (name . ,(openclaw-sandbox-network config)))))))))))

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
                          (secret-names config) (openclaw-secrets config)))
            #:uid #$(openclaw-uid config) #:gid #$(openclaw-gid config)
            #:engine-runtime #$%engine-runtime
            #:sandbox-state '#$%sandbox-state-mounts
            #:setfacl #$(file-append acl "/bin/setfacl")))))))

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
                  ;; Reconcile while the Gateway is stopped, preserving dynamic state.
                  (invoke #$command "stop" "--timeout" "30")
                  (invoke #$(file-append coreutils "/bin/env")
                          (string-append "OPENCLAW_IMAGE=" id)
                          #$command "run" "--rm" "--no-deps" "--pull" "never"
                          "--entrypoint" "node" "gateway"
                          "/etc/openclaw/config.mjs" "reconcile")
                  ;; Validate with the chosen image's own plugin schemas,
                  ;; before starting the long-lived Gateway.
                  (invoke #$(file-append coreutils "/bin/env")
                          (string-append "OPENCLAW_IMAGE=" id)
                          #$command "run" "--rm" "--no-deps" "--pull" "never"
                          "gateway" "node" "openclaw.mjs" "config" "validate")
                  ;; Sandboxes never pull; their image must already be in
                  ;; the engine's persistent store.
                  (invoke #$command "up" "-d" "--pull" "never" "--no-build"
                          "--force-recreate" "--wait" "--wait-timeout" "120"
                          "engine")
                  (invoke #$command "exec" "-T" "engine" "podman" "image" "exists"
                          #$(string-drop (openclaw-sandbox-image config) 7))
                  (invoke #$(file-append coreutils "/bin/env")
                          (string-append "OPENCLAW_IMAGE=" id)
                          #$command "up" "-d" "--pull" "never" "--no-build"
                          "--force-recreate" "--no-deps" "--wait" "--wait-timeout" "180"
                          "gateway")
                  (list image id))
                (lambda args
                  (system* #$command "stop" "--timeout" "30")
                  (apply throw args))))))
       (stop #~(lambda _ (invoke #$command "stop" "--timeout" "30") #f))
       (actions (list (shepherd-configuration-action (openclaw-compose-file config))))))))

(define (openclaw-accounts config)
  ;; Names the dedicated IDs on the host; the containers use them numerically.
  (list (user-group (name "openclaw") (id (openclaw-gid config)) (system? #t))
        (user-account
          (name "openclaw") (uid (openclaw-uid config)) (group "openclaw")
          (system? #t) (comment "OpenClaw Gateway and sandboxes")
          (home-directory "/var/empty") (create-home-directory? #f)
          (shell (file-append shadow "/sbin/nologin")))))

(define openclaw-service-type
  (service-type
    (name 'openclaw)
    (extensions
     (list (service-extension shepherd-root-service-type openclaw-shepherd-services)
           (service-extension account-service-type openclaw-accounts)
           (service-extension sops-secrets-service-type openclaw-secrets)
           (service-extension service-log-service-type
             (lambda (_) (list (service-log (name "openclaw") (containers? #t)))))
           (service-extension etc-service-type
             (lambda (config)
               `(("openclaw/base.json" ,(openclaw-config-file config))
                 ("openclaw/config-plugin"
                  ,(local-file "../../../../scripts/openclaw/config-plugin"
                               #:recursive? #t))
                 ("openclaw/engine-seccomp.json"
                  ,(local-file "../../../../env/docker/openclaw-sandbox-engine/seccomp.json"))
                 ("openclaw/config.mjs"
                  ,(local-file "../../../../scripts/openclaw/config.mjs"))
                 ("openclaw/config-policy.mjs"
                  ,(local-file "../../../../scripts/openclaw/config-policy.mjs"))
                 ("openclaw/compose.json" ,(openclaw-compose-file config))
                 ("openclaw/compose" ,(openclaw-command config)))))))
    (description "Administrator-paired OpenClaw Gateway with sandboxed tool execution.")))
