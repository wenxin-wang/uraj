;;; guix repl -L src/guix -L src/guile test/guix/uraj/services/openclaw.scm
(use-modules (gnu) (gnu services) (gnu services shepherd)
             (guix gexp) (json) (sops secrets) (sops services sops)
             (srfi srfi-1) (srfi srfi-64) (ice-9 rdelim) (ice-9 regex)
             (uraj build openclaw) (uraj packages llm) (uraj services openclaw))

(define image
  (string-append "localhost/openclaw-gateway:2026.10.3@sha256:" (make-string 64 #\a)))
(define provider
  (openclaw-provider (name "new-api") (api "openai-completions")
                     (models '("test-model"))))
(define config
  (openclaw-configuration
    (image image) (secrets-file (plain-file "fixture.yaml" "fixture"))
    (engine-image (string-append "sha256:" (make-string 64 #\c)))
    (sandbox-image (string-append "sha256:" (make-string 64 #\d)))
    (feishu-app-id "cli_test") (model "new-api/test-model")
    (providers (list provider))))
(define (at value . keys)
  (fold (lambda (key value) (assoc-ref value key)) value keys))
(define manifest (json-string->scm (plain-file-content (openclaw-compose-file config))))
(define app (json-string->scm (plain-file-content (openclaw-config-file config))))
(define gateway (at manifest "services" "gateway"))
(define engine (at manifest "services" "engine"))

(test-begin "openclaw")
(define owner-config
  (openclaw-configuration (inherit config)
    (feishu-app-id #f)
    (identity-file (plain-file "identities.yaml" "encrypted fixture"))))
(define owner-manifest
  (json-string->scm (plain-file-content (openclaw-compose-file owner-config))))
(test-equal "identities are separate SOPS inputs" 5
  (length (openclaw-secrets owner-config)))
(test-equal "owner list read only at runtime" "/run/secrets/command-owners"
  (at owner-manifest "services" "gateway" "environment" "OPENCLAW_COMMAND_OWNERS_FILE"))
(test-assert "store config has no command owner identities"
  (not (at (json-string->scm (plain-file-content (openclaw-config-file owner-config)))
           "commands")))
(test-assert "store config has no App ID"
  (not (at (json-string->scm (plain-file-content (openclaw-config-file owner-config)))
           "channels" "feishu" "accounts" "main" "appId")))
(test-equal "App ID read only at runtime" "/run/secrets/feishu-app-id"
  (at owner-manifest "services" "gateway" "environment" "OPENCLAW_FEISHU_APP_ID_FILE"))
(test-error "identity file and literal App ID cannot conflict" #t
  (openclaw-config-file
   (openclaw-configuration (inherit owner-config) (feishu-app-id "cli_test"))))
(test-assert "owner secret is mounted read-only into Gateway"
  (any (lambda (v) (and (equal? (at v "target") "/run/secrets/command-owners")
                        (at v "read_only")))
       (vector->list (at owner-manifest "services" "gateway" "volumes"))))
(define alias-config
  (openclaw-configuration (inherit config)
    (model-aliases '(("new-api/test-model" . "test-6")))))
(test-equal "versioned model alias is serialized" "test-6"
  (at (json-string->scm (plain-file-content (openclaw-config-file alias-config)))
      "agents" "defaults" "models" "new-api/test-model" "alias"))
(for-each
 (lambda (aliases)
   (test-error "invalid or ambiguous alias refused" #t
     (openclaw-config-file
      (openclaw-configuration (inherit config) (model-aliases aliases)))))
 '((("new-api/missing" . "missing-6"))
   (("new-api/test-model" . "bad/name"))
   (("new-api/test-model" . "test-6") ("new-api/test-model" . "other-6"))))
(test-equal "Gateway and sandbox engine" '("engine" "gateway")
  (sort (map car (at manifest "services")) string<?))
(test-equal "only restricted network" '#("restricted") (at gateway "networks"))
(test-equal "engine only on the sandbox network" '#("sandbox") (at engine "networks"))
(test-assert "networks owned externally"
  (and (at manifest "networks" "restricted" "external")
       (at manifest "networks" "sandbox" "external")))
(test-equal "uses static-agent" "static-agent" (at manifest "networks" "restricted" "name"))
(test-equal "sandboxes use their own network" "sandboxed-agents"
  (at manifest "networks" "sandbox" "name"))
(for-each
 (lambda (service)
   (test-assert "no host network or published ports"
     (not (or (at service "ports") (at service "network_mode"))))
   (test-equal "no reboot bypass" "on-failure" (at service "restart"))
   (test-equal "never pulls" "never" (at service "pull_policy"))
   (test-equal "runs as the dedicated user" "2010:2010" (at service "user"))
   (test-equal "no capabilities by default" '#("ALL") (at service "cap_drop")))
 (list gateway engine))
(test-assert "read-only root" (at gateway "read_only"))
(test-assert "native runtime writes are enabled"
  (not (at gateway "environment" "OPENCLAW_CONFIG_READONLY")))
(test-equal "runtime config is persistent at its host path"
  "/data/openclaw/home/.openclaw/openclaw.json"
  (at gateway "environment" "OPENCLAW_CONFIG_PATH"))
(test-equal "Gateway reaches only the nested engine"
  "unix:///run/openclaw-engine/podman.sock"
  (at gateway "environment" "CONTAINER_HOST"))
(test-equal "Gateway waits for a healthy engine" "service_healthy"
  (at gateway "depends_on" "engine" "condition"))
(test-equal "engine regains only ID-mapping capabilities" '#("SETUID" "SETGID")
  (at engine "cap_add"))
(test-equal "engine uses the checked nested seccomp profile"
  '#("seccomp=/etc/openclaw/engine-seccomp.json" "systempaths=unconfined")
  (at engine "security_opt"))
(test-assert "engine is never privileged" (not (at engine "privileged")))
(define gpu-config
  (openclaw-configuration (inherit config)
    (render-device "/dev/dri/renderD128")))
(define gpu-manifest
  (json-string->scm (plain-file-content (openclaw-compose-file gpu-config))))
(test-equal "GPU device reaches engine" '#("/dev/fuse" "/dev/net/tun" "/dev/dri/renderD128")
  (at gpu-manifest "services" "engine" "devices"))
(test-assert "Gateway never receives GPU devices"
  (not (at gpu-manifest "services" "gateway" "devices")))
(test-equal "Podman loads GPU override" "/etc/containers/openclaw-gpu.conf"
  (at gpu-manifest "services" "engine" "environment" "CONTAINERS_CONF_OVERRIDE"))
(test-assert "Podman GPU override is mounted read-only"
  (any (lambda (v)
         (and (equal? (at v "target") "/etc/containers/openclaw-gpu.conf")
              (at v "read_only")))
       (vector->list (at gpu-manifest "services" "engine" "volumes"))))
(test-error "only render devices may be configured" #t
  (openclaw-compose-file
   (openclaw-configuration (inherit config) (render-device "/dev/dri/card0"))))
(define engine-volumes (vector->list (at engine "volumes")))
(test-equal "engine sees workspaces, its store, its socket and sandbox state"
  '(("/data/openclaw/workspaces" . "/data/openclaw/workspaces")
    ("/data/openclaw/engine" . "/home/podman/.local/share/containers")
    ("/run/openclaw-engine" . "/run/openclaw-engine")
    ("/data/openclaw/home/.openclaw/config-proxy"
     . "/data/openclaw/home/.openclaw/config-proxy")
    ("/data/openclaw/home/.openclaw/sandbox/skills-workspaces"
     . "/data/openclaw/home/.openclaw/sandbox/skills-workspaces")
    ("/data/openclaw/home/.openclaw/attachments/subagents"
     . "/data/openclaw/home/.openclaw/attachments/subagents"))
  (map (lambda (v) (cons (at v "source") (at v "target"))) engine-volumes))
(test-assert "engine gets only read-only sandbox state, never config or secrets"
  (every (lambda (v)
           (and (not (string-prefix? "/run/openclaw/" (at v "source")))
                (not (string-prefix? "/etc/" (at v "source")))
                (or (not (string-prefix? "/data/openclaw/home" (at v "source")))
                    (eq? #t (at v "read_only")))))
         engine-volumes))
(test-equal "Feishu uses its built-in typing reaction" #t
  (at app "channels" "feishu" "typingIndicator"))
(test-assert "custom GET receipt is disabled"
  (not (assoc "OPENCLAW_FEISHU_RECEIPT_REACTION" (at gateway "environment"))))
(define volumes (vector->list (at gateway "volumes")))
(test-equal "state and workspaces keep their host paths for sandbox binds" 2
  (count (lambda (v) (and (member (at v "source")
                                  '("/data/openclaw/home" "/data/openclaw/workspaces"))
                          (equal? (at v "source") (at v "target"))
                          (eq? #f (at v "read_only")))) volumes))
(test-assert "no Docker socket or host home"
  (every (lambda (v) (or (string-prefix? "/data/openclaw/" (at v "source"))
                         (string-prefix? "/run/openclaw/" (at v "source"))
                         (equal? "/run/openclaw-engine" (at v "source"))
                         (member (at v "source")
                                 '("/etc/openclaw/base.json"
                                   "/etc/openclaw/config-plugin"
                                   "/etc/openclaw/config.mjs"
                                   "/etc/openclaw/config-policy.mjs"))))
         volumes))
(test-assert "Docker never creates absent bind paths"
  (every (lambda (v) (eq? #f (at v "bind" "create_host_path"))) volumes))
(test-assert "base and checked command are read-only"
  (every (lambda (v) (or (not (string-prefix? "/etc/openclaw/" (at v "target")))
                         (eq? #t (at v "read_only")))) volumes))
(test-equal "checked config plugin is explicitly loaded"
  '#("/etc/openclaw/config-plugin") (at app "plugins" "load" "paths"))
(test-equal "checked config plugin is enabled" #t
  (at app "plugins" "entries" "uraj-config-policy" "enabled"))
(test-equal "persona hooks may gate conversations" #t
  (at app "plugins" "entries" "uraj-config-policy" "hooks" "allowConversationAccess"))
(test-equal "persona drafting may select the shared agent" #t
  (at app "plugins" "entries" "uraj-config-policy" "llm" "allowAgentIdOverride"))
(test-equal "system agent is explicit before Doctor normalization"
  "main" (at app "agents" "defaults" "systemAgent" "agentId"))
(test-equal "shared persona has a separate workspace"
  "/data/openclaw/workspaces/household-shared"
  (at app "agents" "entries" "household-shared" "workspace"))
(test-equal "unbound Feishu conversations use the shared persona"
  "household-shared" (at (vector-ref (at app "bindings") 0) "agentId"))
(test-equal "exec never falls back to the Gateway" "sandbox"
  (at app "tools" "exec" "host"))
(test-equal "elevated escape is disabled" #f (at app "tools" "elevated" "enabled"))
(test-equal "heartbeat notifications stay internal"
  "none" (at app "agents" "defaults" "heartbeat" "target"))

(define sandbox (at app "agents" "defaults" "sandbox"))
(test-equal "managed proxy permits an external bind source" #t
  (at sandbox "docker" "dangerouslyAllowExternalBindSources"))
(test-equal "sandbox exposes only the config proxy endpoint and client"
  '#("/data/openclaw/home/.openclaw/config-proxy:/run/openclaw-config:ro"
     "/data/openclaw/home/.openclaw/config-proxy/openclaw:/usr/local/bin/openclaw:ro")
  (at sandbox "docker" "binds"))
(test-equal "every session is sandboxed" "all" (at sandbox "mode"))
(test-equal "sandbox uses the Podman engine" "podman" (at sandbox "backend"))
(test-equal "sandbox writes the host workspace" "rw" (at sandbox "workspaceAccess"))
(let* ((auto (openclaw-configuration (inherit config) (sandbox-image #f)))
       (gateway (at (json-string->scm (plain-file-content (openclaw-compose-file auto)))
                    "services" "gateway")))
  (test-assert "Podman build context is mounted read-only"
    (let ((engine (at (json-string->scm (plain-file-content (openclaw-compose-file auto)))
                      "services" "engine")))
      (any (lambda (mount)
             (and (equal? (at mount "target") "/etc/openclaw/sandbox-build")
                  (at mount "read_only")
                  (not (at mount "bind" "create_host_path"))))
           (vector->list (at engine "volumes")))))
  (test-equal "automatic build exposes the image ID file to managed configuration"
    "/run/openclaw/sandbox-image"
    (at gateway "environment" "OPENCLAW_SANDBOX_IMAGE_FILE"))
  (test-assert "built image ID is mounted read-only without creating missing files"
    (any (lambda (mount)
           (and (equal? (at mount "target") "/run/openclaw/sandbox-image")
                (at mount "read_only")
                (not (at mount "bind" "create_host_path"))))
         (vector->list (at gateway "volumes")))))
(test-equal "sandbox image is the declared local ID" (make-string 64 #\d)
  (at sandbox "docker" "image"))
(test-equal "sandbox user matches the engine's keep-id mapping" "2010:2010"
  (at sandbox "docker" "user"))
(test-equal "sandbox egress through the engine network" "pasta"
  (at sandbox "docker" "network"))
(test-assert "sandbox root is read-only without capabilities"
  (and (at sandbox "docker" "readOnlyRoot")
       (equal? '#("ALL") (at sandbox "docker" "capDrop"))))
(test-equal "agent paths are host paths" "/data/openclaw/workspaces/main"
  (at app "agents" "entries" "main" "workspace"))
(test-equal "Gateway-run tools are allowed in sandboxed sessions"
  '#("openclaw_config_set" "web_fetch" "memory_search" "memory_get" "message")
  (at app "tools" "sandbox" "tools" "alsoAllow"))
(test-equal "message tool never crosses to another provider" #f
  (at app "tools" "message" "crossContext" "allowAcrossProviders"))
(test-error "engine image must be a local ID" #t
  (openclaw-compose-file (openclaw-configuration (inherit config)
                           (engine-image "quay.io/podman/stable"))))
(test-error "root sandbox user refused" #t
  (openclaw-config-file (openclaw-configuration (inherit config) (uid 0))))
(test-equal "exec uses canonical full mode" "full"
  (at app "tools" "exec" "mode"))
(test-assert "no legacy exec fields for Doctor to rewrite"
  (and (not (assoc "security" (at app "tools" "exec")))
       (not (assoc "ask" (at app "tools" "exec")))))
(test-equal "secrets are read-only individual mounts" 3
  (count (lambda (v) (and (string-prefix? "/run/secrets/" (at v "target"))
                          (at v "read_only"))) volumes))
(test-equal "WebSocket needs no ingress" "websocket" (at app "channels" "feishu" "connectionMode"))
(test-assert "no preconfigured sender bypasses pairing"
  (not (at app "channels" "feishu" "allowFrom")))
(test-equal "DMs require administrator pairing approval" "pairing"
  (at app "channels" "feishu" "dmPolicy"))
(test-equal "invited groups enabled" "open" (at app "channels" "feishu" "groupPolicy"))
(test-equal "groups require a bot mention" #t
  (at app "channels" "feishu" "requireMention"))
(test-equal "only Feishu groups opt into native silent replies"
  '(("feishu" . (("silentReply" . (("group" . "allow"))))))
  (at app "surfaces"))
(test-equal "each group topic has its own session" "group_topic"
  (at app "channels" "feishu" "groupSessionScope"))
(test-equal "bot replies stay in topic threads" "enabled"
  (at app "channels" "feishu" "replyInThread"))
(test-equal "file, process, web, memory, message and config tools explicitly allowed"
  '#("read" "write" "edit" "apply_patch" "exec" "process"
     "view_image" "web_fetch" "memory_search" "memory_get" "message"
     "openclaw_config_set")
  (at app "tools" "allow"))
(test-assert "file tools are not blocked by the old deny-all policy"
  (not (at app "tools" "deny")))
(test-equal "file tools restricted to workspace" #t
  (at app "tools" "fs" "workspaceOnly"))
(test-equal "patch tool enabled for bootstrap cleanup" #t
  (at app "tools" "exec" "applyPatch" "enabled"))
(test-equal "patch tool restricted to workspace" #t
  (at app "tools" "exec" "applyPatch" "workspaceOnly"))
(test-assert "Feishu document tools disabled"
  (every (lambda (entry) (eq? #f (cdr entry))) (at app "channels" "feishu" "tools")))
(test-equal "provider uses file SecretRef" "new-api-token"
  (at app "models" "providers" "new-api" "apiKey" "provider"))
(test-assert "models are text-only by default"
  (not (assoc "input" (vector-ref (at app "models" "providers" "new-api" "models") 0))))
(test-equal "image input declared per model" #("text" "image")
  (at (vector-ref
       (at (json-string->scm
            (plain-file-content
             (openclaw-config-file
              (openclaw-configuration (inherit config)
                (providers (list (openclaw-provider (inherit provider)
                                   (image-input? #t))))))))
           "models" "providers" "new-api" "models")
       0)
      "input"))
(test-assert "prompt cache key is opt-in"
  (not (assoc "compat" (vector-ref (at app "models" "providers" "new-api" "models") 0))))
(test-equal "prompt cache key declared per model" #t
  (at (vector-ref
       (at (json-string->scm
            (plain-file-content
             (openclaw-config-file
              (openclaw-configuration (inherit config)
                (providers (list (openclaw-provider (inherit provider)
                                   (prompt-cache-key? #t))))))))
           "models" "providers" "new-api" "models")
       0)
      "compat" "supportsPromptCacheKey"))
(define multi-model-app
  (json-string->scm
   (plain-file-content
    (openclaw-config-file
     (openclaw-configuration (inherit config)
       (providers (list (openclaw-provider (inherit provider)
                          (models '("test-model" "second-model" "second-model"
                                    "third-model"))))))))))
(test-equal "model catalog includes default and distinct additional models"
  '("test-model" "second-model" "third-model")
  (map (lambda (model) (at model "id"))
       (vector->list (at multi-model-app "models" "providers" "new-api" "models"))))
(test-equal "additional choices do not change the default" "new-api/test-model"
  (at multi-model-app "agents" "defaults" "model" "primary"))
(test-error "empty model choice refused" #t
  (openclaw-config-file
   (openclaw-configuration (inherit config)
     (providers (list (openclaw-provider (inherit provider) (models '(""))))))))

(define family-providers
  (list (openclaw-provider (name "new-api-gpt") (api "openai-responses")
                           (reasoning-models '("gpt-test"))
                           (models '("gpt-test" "shared-model")))
        (openclaw-provider (name "new-api-claude") (api "anthropic-messages")
                           (models '("claude-test" "shared-model")))
        (openclaw-provider (name "new-api-deepseek") (api "openai-completions")
                           (models '("deepseek-test")))))
(define family-config
  (openclaw-configuration (inherit config) (model "new-api-claude/claude-test")
                          (providers family-providers)))
(define family-app
  (json-string->scm (plain-file-content (openclaw-config-file family-config))))
(for-each
 (lambda (name api url models)
   (let ((row (at family-app "models" "providers" name)))
     (test-equal "provider keeps its API protocol" api (at row "api"))
     (test-equal "API has the correct endpoint base" url (at row "baseUrl"))
     (test-equal "provider retains its own model catalog" models
       (map (lambda (model) (at model "id")) (vector->list (at row "models"))))
     (test-equal "all providers reuse the existing secret" "new-api-token"
       (at row "apiKey" "provider"))))
 '("new-api-gpt" "new-api-claude" "new-api-deepseek")
 '("openai-responses" "anthropic-messages" "openai-completions")
 '("http://172.31.0.9:3000/v1" "http://172.31.0.9:3000" "http://172.31.0.9:3000/v1")
 '(("gpt-test" "shared-model") ("claude-test" "shared-model") ("deepseek-test")))
(test-equal "default can select any provider" "new-api-claude/claude-test"
  (at family-app "agents" "defaults" "model" "primary"))
(let ((models (at family-app "models" "providers" "new-api-gpt" "models")))
  (test-equal "custom reasoning model declares its capability" #t
    (at (vector-ref models 0) "reasoning"))
  (test-assert "other models retain catalog capability defaults"
    (not (assoc "reasoning" (vector-ref models 1)))))
(test-error "reasoning model must belong to the provider" #t
  (openclaw-config-file
   (openclaw-configuration (inherit config)
     (providers (list (openclaw-provider (inherit provider)
                        (reasoning-models '("absent"))))))))
(for-each
 (lambda (providers)
   (test-error "invalid provider declarations refused" #t
     (openclaw-config-file
      (openclaw-configuration (inherit config) (providers providers)))))
 (list '() (list provider provider)
       (list (openclaw-provider (inherit provider) (name "New/API")))
       (list (openclaw-provider (inherit provider) (api "unknown")))
       (list (openclaw-provider (inherit provider) (base-url "file:///tmp/api")))
       (list (openclaw-provider (inherit provider) (models '())))))
(for-each
 (lambda (model)
   (test-error "unknown or unqualified default refused" #t
     (openclaw-config-file (openclaw-configuration (inherit family-config) (model model)))))
 '("gpt-test" "new-api-gpt/absent" "absent/gpt-test"))
(test-equal "explicit base URL supported" "https://models.example.test/v1"
  (at (json-string->scm
       (plain-file-content
        (openclaw-config-file
         (openclaw-configuration (inherit config)
           (providers (list (openclaw-provider (inherit provider)
                              (base-url "https://models.example.test/v1"))))))))
      "models" "providers" "new-api" "baseUrl"))
(test-equal "Gateway uses file SecretRef" "gateway-token"
  (at app "gateway" "auth" "token" "provider"))
(test-equal "Feishu uses file SecretRef" "feishu-app-secret"
  (at app "channels" "feishu" "accounts" "main" "appSecret" "provider"))
(test-equal "plain restart restores pinned declaration" image (openclaw-image-for-tag image #f))
(test-equal "temporary tag removes digest" "localhost/openclaw-gateway:trial"
  (openclaw-image-for-tag image "trial"))
(test-equal "local image ID selects the configured repository" "localhost/custom:trial"
  (openclaw-image-for-tag (string-append "sha256:" (make-string 64 #\b))
                          "trial" "localhost/custom"))
(test-assert "locally built immutable IDs are accepted"
  (openclaw-compose-file
   (openclaw-configuration (inherit config)
     (image (string-append "sha256:" (make-string 64 #\b))))))
(test-equal "registry port preserved" "registry:5000/openclaw:trial"
  (openclaw-image-for-tag (string-append "registry:5000/openclaw@sha256:" (make-string 64 #\a)) "trial"))
(for-each (lambda (tag)
            (test-error "invalid temporary version rejected" #t
              (openclaw-image-for-tag image tag)))
          (list "" "-x" ".x" "a:b" "a/b" "x@sha256" "a b" (make-string 129 #\a)))
(test-error "moving default tag refused" #t
  (openclaw-compose-file (openclaw-configuration (inherit config) (image "repo:latest"))))
(test-error "invalid app ID refused" #t
  (openclaw-config-file (openclaw-configuration (inherit config) (feishu-app-id "*"))))

;; Exercise the actual Guix service composition, including SOPS extension.
(unsetenv "TO_ISO")
(define base (load (string-append (getcwd) "/env/guix/os/storie.scm")))
(define deployed-service
  (find (lambda (s) (eq? openclaw-service-type (service-kind s)))
        (operating-system-user-services base)))
(test-assert "storie declares OpenClaw" deployed-service)
(test-assert "real deployment configuration validates"
  (openclaw-config-file (service-value deployed-service)))
(let* ((app (json-string->scm
             (plain-file-content
              (openclaw-config-file (service-value deployed-service)))))
       (providers (at app "models" "providers")))
  (for-each
   (lambda (provider)
     (for-each
      (lambda (model)
        (test-equal
         (string-append "storie declares reasoning for " (car provider)
                        "/" (at model "id"))
         #t (at model "reasoning")))
      (vector->list (at (cdr provider) "models"))))
   providers))
(let* ((app (json-string->scm
             (plain-file-content
              (openclaw-config-file (service-value deployed-service)))))
       (primary (string-split (at app "agents" "defaults" "model" "primary") #\/))
       (provider (at app "models" "providers" (car primary)))
       (model (find (lambda (row) (equal? (at row "id") (cadr primary)))
                    (vector->list (at provider "models")))))
  (test-equal "storie default uses Responses" "openai-responses"
    (at provider "api"))
  (test-equal "storie default declares reasoning for developer instructions" #t
    (at model "reasoning")))
(setenv "TO_ISO" "1")
(define live (load (string-append (getcwd) "/env/guix/os/storie.scm")))
(unsetenv "TO_ISO")
(test-assert "installer omits OpenClaw"
  (not (any (lambda (s) (eq? openclaw-service-type (service-kind s)))
            (operating-system-user-services live))))
(define os
  (operating-system (inherit base)
    (services (cons (service openclaw-service-type config)
                    (remove (lambda (s) (eq? openclaw-service-type (service-kind s)))
                            (operating-system-user-services base))))))
(define all
  (shepherd-configuration-services
   (service-value (fold-services (operating-system-services os)
                                #:target-type shepherd-root-service-type))))
(define service (find (lambda (s) (memq 'openclaw (shepherd-service-provision s))) all))
(test-assert "Gateway waits for firewall, secrets, storage, Docker and logging"
  (every (lambda (r) (memq r (shepherd-service-requirement service)))
         '(restricted-network sops-secrets file-system-/data dockerd syslogd)))
(define secrets
  (filter (lambda (s) (equal? "openclaw" (car (sops-secret-key s))))
          (sops-service-configuration-secrets
           (service-value (fold-services (operating-system-services os)
                                        #:target-type sops-secrets-service-type)))))
(test-equal "three independent credentials from one encrypted file" 3 (length secrets))
(test-assert "decrypted inputs root-only"
  (every (lambda (s) (and (equal? "root" (sops-secret-user s))
                          (= #o400 (sops-secret-permissions s)))) secrets))

(test-assert "preparation bundles its runtime module and Guix dependencies"
  (let ((modules (gexp-modules
                  (program-file-gexp (openclaw-prepare-program config)))))
    (every (lambda (name) (member name modules))
           '((uraj build openclaw) (guix build syscalls)))))

;; A hot upgrade must not import repository modules into the running daemon.
(test-equal "start closure needs no imported module tree" '()
  (gexp-modules (shepherd-service-start service)))

;; Execute the generated start closure without Docker or real credentials.
(define* (start tag #:key (missing? #f) (fail-up? #f) (fail-validation? #f)
                (fail-reconcile? #f) (fail-image? #f)
                (absent-sandbox? #f) (fail-import? #f) (engine-error? #f) (auto-build? #f) (fail-build? #f))
  (let ((m (make-fresh-user-module)) (calls '()) (stopped? #f))
    (for-each (lambda (interface) (module-use! m (resolve-interface interface)))
              (remove (lambda (interface) (member interface %default-modules))
                      (shepherd-service-modules service)))
    (module-define! m 'file-exists? (lambda (_) #f))
    (module-define! m 'call-with-input-file
      (lambda (file proc)
        (proc (open-input-string (string-append "sha256:" (make-string 64 #\e))))))
    (module-define! m '*approximate* (lambda () 'program))
    (module-define! m 'open-pipe*
      (lambda args (open-input-string "sha256:resolved-local-image\n")))
    (module-define! m 'close-pipe (lambda (_) (if missing? 1 0)))
    (module-define! m 'invoke
      (lambda args
        (set! calls (cons args calls))
        (when (and fail-build? (member "build" args))
          (error "simulated build failure"))
        (when (and fail-reconcile? (member "reconcile" args))
          (error "simulated policy failure"))
        (when (and fail-validation? (member "validate" args))
          (error "simulated schema failure"))
        (when (and fail-import? (member "openclaw-import-sandbox" args))
          (error "simulated import failure"))
        (when (and fail-image? (member "exists" args)) (error "simulated missing image"))
        (when (and fail-up? (member "up" args)) (error "simulated failed startup"))))
    (module-define! m 'system*
      (lambda args
        (if (member "exists" args)
            (begin
              (set! calls (cons args calls))
              (cond (engine-error? (* 125 256))
                    (absent-sandbox? 256)
                    (else 0)))
            (begin (set! stopped? #t) 0))))
    (let* ((proc (eval (gexp->approximate-sexp
                         (shepherd-service-start
                          (if auto-build?
                              (car ((@@ (uraj services openclaw) openclaw-shepherd-services)
                                    (openclaw-configuration (inherit config)
                                      (sandbox-image #f))))
                              service))) m))
           (result (catch #t (lambda () (proc tag)) (lambda _ #f))))
      (list result (reverse calls) stopped?))))
(let* ((result (start "trial")) (up (last (cadr result))))
  (test-equal "reports requested version and immutable image ID"
    '("localhost/openclaw-gateway:trial" "sha256:resolved-local-image") (car result))
  (test-assert "executes resolved ID with no pulls or builds"
    (and (member "OPENCLAW_IMAGE=sha256:resolved-local-image" up)
         (member "never" up) (member "--no-build" up) (member "--force-recreate" up))))
(let* ((calls (cadr (start #f)))
       (ups (filter (lambda (call) (member "up" call)) calls)))
  (test-equal "engine is started only once" "engine" (last (car ups)))
  (test-assert "Gateway startup cannot recreate the checked engine"
    (and (= 2 (length ups))
         (equal? "gateway" (last (cadr ups)))
         (member "--no-deps" (cadr ups)))))
(test-equal "missing local image never prepares files or starts containers"
  '(#f () #f) (start "absent" #:missing? #t))
(test-assert "failed Compose start stops the partial stack" (caddr (start #f #:fail-up? #t)))
(let ((result (start #f #:fail-validation? #t)))
  (test-assert "invalid image schema never starts Gateway"
    (and (not (car result))
         (not (any (lambda (call) (member "up" call)) (cadr result))))))
(test-equal "plain start selects declared digest" image (caar (start #f)))
(test-assert "reconciliation failure never starts Gateway"
  (let ((result (start #f #:fail-reconcile? #t)))
    (and (not (car result))
         (not (any (lambda (call) (member "up" call)) (cadr result))))))
(test-equal "stop and reconcile precede validation, engine and Gateway startup"
  '("stop" "reconcile" "validate" "up" "exists" "exists" "up")
  (filter-map (lambda (call)
                (find (lambda (word) (member word call))
                      '("stop" "reconcile" "validate" "up" "exists")))
              (cadr (start #f))))
(test-assert "missing sandbox image never starts Gateway"
  (let ((result (start #f #:fail-image? #t)))
    (and (not (car result)) (caddr result)
         (= 1 (count (lambda (call) (member "up" call)) (cadr result))))))
(test-assert "existing sandbox image skips import"
  (not (any (lambda (call) (member "openclaw-import-sandbox" call))
            (cadr (start #f)))))
(let* ((result (start #f #:absent-sandbox? #t))
       (calls (cadr result))
       (import (find (lambda (call) (member "openclaw-import-sandbox" call)) calls)))
  (test-assert "absent sandbox is streamed from Docker using the pinned ID"
    (and (car result) import (member "pipefail" import)
         (equal? (last import) (string-append "sha256:" (make-string 64 #\d)))))
  (test-equal "import precedes verification and Gateway startup"
    '("openclaw-import-sandbox" "exists" "up")
    (filter-map (lambda (call)
                  (find (lambda (word) (member word call))
                        '("openclaw-import-sandbox" "exists" "up")))
                (member import calls))))
(for-each
 (lambda (result)
   (test-assert "failed import or engine check stops stack before Gateway"
     (and (not (car result)) (caddr result)
          (= 1 (count (lambda (call) (member "up" call)) (cadr result))))))
 (list (start #f #:absent-sandbox? #t #:fail-import? #t)
       (start #f #:absent-sandbox? #t #:fail-image? #t)
       (start #f #:engine-error? #t)))
(let* ((result (start #f #:auto-build? #t))
       (calls (cadr result)))
  (test-assert "automatic Podman build verifies its resulting ID without importing"
    (and (car result)
         (any (lambda (call)
                (and (member "exists" call)
                     (equal? (last call) (make-string 64 #\e))))
              calls)
         (not (any (lambda (call) (member "openclaw-import-sandbox" call)) calls))))
  (test-assert "build runs inside engine with persistent layers and configured IDs"
    (let ((build (find (lambda (call) (member "build" call)) calls)))
      (and build
           (every (lambda (word) (member word build))
                  '("exec" "-T" "engine" "podman" "--layers" "--network=host"
                    "UID=2010" "GID=2010"))
           (equal? (last build) "/etc/openclaw/sandbox-build"))))
  (test-equal "engine startup and build precede reconcile and Gateway startup"
    '("stop" "up" "build" "reconcile" "validate" "exists" "up")
    (filter-map (lambda (call)
                  (find (lambda (word) (member word call))
                        '("stop" "build" "reconcile" "validate" "up" "exists"
                          "openclaw-import-sandbox"))) calls)))
(let ((result (start #f #:auto-build? #t #:fail-build? #t)))
  (test-assert "failed build stops engine without reconciliation or Gateway"
    (and (not (car result)) (caddr result)
         (= 1 (count (lambda (call) (member "up" call)) (cadr result)))
         (not (any (lambda (call) (member "reconcile" call)) (cadr result))))))
(test-equal "invalid tag has no effects" '(#f () #f) (start "../bad"))
(test-assert "no skills: no skill mount or load path"
  (and (not (at app "skills"))
       (not (any (lambda (v) (equal? "/etc/openclaw/skills" (at v "target")))
                 volumes))))
(let* ((skill-config (openclaw-configuration (inherit config)
                       (skills `(("agent-browser" ,(plain-file "SKILL.md" "x"))))))
       (skill-app (json-string->scm (plain-file-content
                                     (openclaw-config-file skill-config))))
       (skill-gateway (at (json-string->scm (plain-file-content
                                             (openclaw-compose-file skill-config)))
                          "services" "gateway")))
  (test-equal "declared skills load from their read-only mount"
    '#("/etc/openclaw/skills") (at skill-app "skills" "load" "extraDirs"))
  (test-assert "skill directory is mounted read-only"
    (any (lambda (v) (and (equal? "/etc/openclaw/skills" (at v "source"))
                          (equal? "/etc/openclaw/skills" (at v "target"))
                          (at v "read_only")))
         (vector->list (at skill-gateway "volumes")))))
(for-each
 (lambda (skills)
   (test-error "invalid or duplicate skill refused" #t
     (openclaw-config-file (openclaw-configuration (inherit config) (skills skills)))))
 `((("../x" ,(plain-file "x" "x")))
   (("a" ,(plain-file "x" "x")) ("a" ,(plain-file "y" "y")))))
(test-equal "sandbox image ships the Guix agent-browser version"
  (package-version agent-browser)
  (call-with-input-file "env/docker/openclaw-sandbox/Dockerfile"
    (lambda (port)
      (let loop ()
        (let ((line (read-line port)))
          (cond ((eof-object? line) #f)
                ((string-match "^ARG AGENT_BROWSER_VERSION=(.*)$" line)
                 => (lambda (m) (match:substring m 1)))
                (else (loop))))))))

(define failures (test-runner-fail-count (test-runner-current)))
(test-end "openclaw")
(exit (if (zero? failures) 0 1))
