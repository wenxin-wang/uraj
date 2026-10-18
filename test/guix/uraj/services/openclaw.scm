;;; guix repl -L src/guix -L src/guile test/guix/uraj/services/openclaw.scm
(use-modules (gnu) (gnu services) (gnu services shepherd)
             (guix gexp) (json) (sops secrets) (sops services sops)
             (srfi srfi-1) (srfi srfi-64)
             (uraj build openclaw) (uraj services openclaw))

(define image
  (string-append "localhost/openclaw-feishu:2026.10.3@sha256:" (make-string 64 #\a)))
(define provider
  (openclaw-provider (name "new-api") (api "openai-completions")
                     (models '("test-model"))))
(define config
  (openclaw-configuration
    (image image) (secrets-file (plain-file "fixture.yaml" "fixture"))
    (feishu-app-id "cli_test") (model "new-api/test-model")
    (providers (list provider))))
(define (at value . keys)
  (fold (lambda (key value) (assoc-ref value key)) value keys))
(define manifest (json-string->scm (plain-file-content (openclaw-compose-file config))))
(define app (json-string->scm (plain-file-content (openclaw-config-file config))))
(define gateway (at manifest "services" "gateway"))

(test-begin "openclaw")
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
(test-equal "one container" '("gateway") (map car (at manifest "services")))
(test-equal "only restricted network" '#("restricted") (at gateway "networks"))
(test-assert "network owned externally" (at manifest "networks" "restricted" "external"))
(test-equal "uses static-agent" "static-agent" (at manifest "networks" "restricted" "name"))
(test-assert "no host network or published ports"
  (not (or (at gateway "ports") (at gateway "network_mode"))))
(test-equal "no reboot bypass" "on-failure" (at gateway "restart"))
(test-equal "never pulls" "never" (at gateway "pull_policy"))
(test-equal "runs non-root" "1000:1000" (at gateway "user"))
(test-assert "read-only root" (at gateway "read_only"))
(test-equal "Doctor knows config is externally managed" "1"
  (at gateway "environment" "OPENCLAW_CONFIG_READONLY"))
(test-equal "Feishu uses its built-in typing reaction" #t
  (at app "channels" "feishu" "typingIndicator"))
(test-assert "custom GET receipt is disabled"
  (not (assoc "OPENCLAW_FEISHU_RECEIPT_REACTION" (at gateway "environment"))))
(test-equal "no capabilities" '#("ALL") (at gateway "cap_drop"))
(define volumes (vector->list (at gateway "volumes")))
(test-equal "whole home is a writable persistent mount" 1
  (count (lambda (v) (and (equal? "/data/openclaw/home" (at v "source"))
                          (equal? "/home/node" (at v "target"))
                          (eq? #f (at v "read_only")))) volumes))
(test-assert "no Docker socket or host home"
  (every (lambda (v) (or (string-prefix? "/data/openclaw/" (at v "source"))
                         (string-prefix? "/run/openclaw/" (at v "source"))
                         (equal? "/etc/openclaw/openclaw.json" (at v "source"))))
         volumes))
(test-assert "Docker never creates absent bind paths"
  (every (lambda (v) (eq? #f (at v "bind" "create_host_path"))) volumes))
(test-equal "secrets are read-only individual mounts" 3
  (count (lambda (v) (and (string-prefix? "/run/secrets/" (at v "target"))
                          (at v "read_only"))) volumes))
(test-equal "WebSocket needs no ingress" "websocket" (at app "channels" "feishu" "connectionMode"))
(test-assert "no preconfigured sender bypasses pairing"
  (not (at app "channels" "feishu" "allowFrom")))
(test-equal "DMs require administrator pairing approval" "pairing"
  (at app "channels" "feishu" "dmPolicy"))
(test-equal "groups disabled" "disabled" (at app "channels" "feishu" "groupPolicy"))
(test-equal "all model-facing tools denied" '#("*") (at app "tools" "deny"))
(test-assert "Feishu document tools disabled"
  (every (lambda (entry) (eq? #f (cdr entry))) (at app "channels" "feishu" "tools")))
(test-equal "provider uses file SecretRef" "new-api-token"
  (at app "models" "providers" "new-api" "apiKey" "provider"))
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
(test-equal "temporary tag removes digest" "localhost/openclaw-feishu:trial"
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
(define* (start tag #:key (missing? #f) (fail-up? #f) (fail-validation? #f))
  (let ((m (make-fresh-user-module)) (calls '()) (stopped? #f))
    (for-each (lambda (interface) (module-use! m (resolve-interface interface)))
              (remove (lambda (interface) (member interface %default-modules))
                      (shepherd-service-modules service)))
    (module-define! m '*approximate* (lambda () 'program))
    (module-define! m 'open-pipe*
      (lambda args (open-input-string "sha256:resolved-local-image\n")))
    (module-define! m 'close-pipe (lambda (_) (if missing? 1 0)))
    (module-define! m 'invoke
      (lambda args
        (set! calls (cons args calls))
        (when (and fail-validation? (member "validate" args))
          (error "simulated schema failure"))
        (when (and fail-up? (member "up" args)) (error "simulated failed startup"))))
    (module-define! m 'system* (lambda _ (set! stopped? #t) 0))
    (let* ((proc (eval (gexp->approximate-sexp (shepherd-service-start service)) m))
           (result (catch #t (lambda () (proc tag)) (lambda _ #f))))
      (list result (reverse calls) stopped?))))
(let* ((result (start "trial")) (up (last (cadr result))))
  (test-equal "reports requested version and immutable image ID"
    '("localhost/openclaw-feishu:trial" "sha256:resolved-local-image") (car result))
  (test-assert "executes resolved ID with no pulls or builds"
    (and (member "OPENCLAW_IMAGE=sha256:resolved-local-image" up)
         (member "never" up) (member "--no-build" up) (member "--force-recreate" up))))
(test-equal "missing local image never prepares files or starts containers"
  '(#f () #f) (start "absent" #:missing? #t))
(test-assert "failed Compose start stops the partial stack" (caddr (start #f #:fail-up? #t)))
(let ((result (start #f #:fail-validation? #t)))
  (test-assert "invalid image schema never starts Gateway"
    (and (not (car result))
         (not (any (lambda (call) (member "up" call)) (cadr result))))))
(test-equal "plain start selects declared digest" image (caar (start #f)))
(test-equal "invalid tag has no effects" '(#f () #f) (start "../bad"))

(define failures (test-runner-fail-count (test-runner-current)))
(test-end "openclaw")
(exit (if (zero? failures) 0 1))
