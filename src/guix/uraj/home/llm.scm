(define-module (uraj home llm)
  #:use-module (gnu home)
  #:use-module (gnu home services)
  #:use-module (gnu packages version-control)
  #:use-module (gnu packages ssh)
  #:use-module (gnu packages base)
  #:use-module (gnu packages bash)
  #:use-module (gnu services)
  #:use-module (guix gexp)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module (uraj common basic-services)
  #:use-module (uraj common context)
  #:use-module (uraj home paseo-broker)
  #:use-module (uraj home paseo)
  #:use-module (uraj packages llm)
  #:use-module (uraj utils file path)
  #:export (home-agent-skills-service-type
            agent-common-services
            agent-desktop-services agent-headless-services contained-agent))

;;; Agent skills: a list of (NAME DIRECTORY) entries, DIRECTORY being a
;;; file-like skill directory containing SKILL.md (use file-append to pick a
;;; sub-directory of a package or origin).  Each skill is linked as NAME into
;;; every directory below, straight to the store rather than through
;;; ~/.agents/skills, so no link depends on another.  Only individual skills
;;; are linked: the directories themselves stay writable for skills installed
;;; by hand, e.g. with `npx skills add' while trying one out.
(define %agent-skill-directories
  ;; Codex and other agents following the shared convention, then Claude Code.
  '(".agents/skills" ".claude/skills"))

(define (agent-skills-home-files skills)
  (append-map
   (match-lambda
     ((name directory)
      (map (lambda (parent)
             (list (string-append parent "/" name) directory))
           %agent-skill-directories)))
   skills))

(define home-agent-skills-service-type
  (service-type
   (name 'home-agent-skills)
   (extensions
    (list (service-extension home-files-service-type
                             agent-skills-home-files)))
   (compose concatenate)
   (extend append)
   (default-value '())
   (description "Link skill directories for coding agents into their skill
search paths.")))

(define llm-agent-packages
  (list agent-browser claude-code codex))

(define %agent-skills
  `(("agent-browser"
     ,(file-append agent-browser "/share/agent-browser/skills/agent-browser"))))

(define (agent-common-services)
  "Return the coding agents and their skills, shared by desktop Homes and the
headless Homes."
  (list
   (simple-service 'llm-agent-packages
                   home-profile-service-type
                   llm-agent-packages)
   (service home-agent-skills-service-type %agent-skills)))

;;; contained-agent: each agent runs in a per-project `guix shell
;;; --container' (see (uraj bin contained-agent)).  Specs are data; ~ is the
;;; home directory.
(define %contained-agent-specs
  #~(list
     (cons "codex"
           `((program . #$(file-append codex "/bin/codex"))
             (state "~/.codex")
             ;; Skills installed in a session last until it ends; keep one
             ;; through %agent-skills or a host-side install.
             (overlay "~/.agents/skills" "~/.codex/skills" "~/.codex/plugins"
                      "~/.codex/.tmp" "~/.codex/vendor_imports"
                      "~/.codex/ipc" "~/.codex/computer-use")
             (protect "~/.codex/config.toml" "~/.codex/AGENTS.md"
                      "~/.codex/rules/")
             (preserve "CODEX_.*" "OPENAI_.*")))
     ;; Everything under ~/.claude is the session's own but for the
     ;; transcripts, memory and history it persists.  ~/.claude.json
     ;; (project trust, MCP servers...) starts from the host's and is
     ;; dropped too.
     (cons "claude"
           `((program . #$(file-append claude-code "/bin/claude"))
             (overlay "~/.claude")
             (persist "~/.claude/projects/" "~/.claude/sessions/"
                      "~/.claude/session-env/" "~/.claude/file-history/"
                      "~/.claude/paste-cache/" "~/.claude/todos/"
                      "~/.claude/plans/" "~/.claude/tasks/"
                      "~/.claude/history.jsonl")
             (seed "~/.claude.json")
             (preserve "CLAUDE_.*" "ANTHROPIC_.*")))))

(define %contained-agent-common
  ;; Long-term memory is read-only: one prompt injection written there would
  ;; reach every later session.
  '((share "~/.llm-memory")
    ;; Paseo sends Codex localImage paths below its private TMPDIR. Keep the
    ;; same path in both namespaces, including files uploaded after launch.
    (expose "~/.cache/paseo-tmp"
            "~/src" "~/.llm-wiki" "~/.gitconfig" "~/.gitconfig.local")
    (preserve "TERM" "COLORTERM" "LANG" "LC_.*" "NO_COLOR" "PASEO_.*"
              "RUST_LOG")))

(define %contained-agent-packages
  ;; bubblewrap provides bwrap for Codex's own command sandbox and overlays.
  ;; Keep common scripting, download and archive tools available to every agent.
  ;; python-wrapper supplies both python and python3.
  '("bash" "bc" "bubblewrap" "bzip2" "coreutils" "curl" "diffutils" "file"
    "findutils" "gawk" "git" "git-lfs" "grep" "gzip" "jq" "less"
    "nss-certs" "patch" "perl" "procps" "python-wrapper" "ripgrep" "sed" "tar"
    "unzip" "wget" "which" "xz" "zip"))

(define contained-agent
  (program-file
   "contained-agent"
   (with-imported-modules '((uraj bin contained-agent) (uraj bin contained-ssh))
     #~(begin
         (use-modules (uraj bin contained-agent))
         (contained-agent-main (command-line)
                               #:agents #$%contained-agent-specs
                               #:common '#$%contained-agent-common
                               #:packages '#$%contained-agent-packages
                               #:ssh-tools
                               (list (cons 'ssh-agent #$(file-append openssh "/bin/ssh-agent"))
                                     (cons 'ssh-add #$(file-append openssh "/bin/ssh-add"))
                                     (cons 'sha256sum #$(file-append coreutils "/bin/sha256sum"))
                                     (cons 'bash #$(file-append bash-minimal "/bin/bash")))
                               #:git #$(file-append git "/bin/git"))))))

(define (contained-agent-link name)
  ;; A store item that is itself a link, so every name resolves to the one
  ;; program.
  (computed-file name #~(symlink #$contained-agent #$output)))

(define (contained-agent-home-files)
  `((".local/bin/contained-agent" ,contained-agent)
    (".local/bin/codex" ,(contained-agent-link "codex"))
    (".local/bin/claude" ,(contained-agent-link "claude"))))

(define llm-desktop-packages
  (list paseo))

(define (agent-headless-services)
  "Install agents and Paseo in the existing user's Home, without desktop apps
or a second user Shepherd broker. Agent settings remain user-managed."
  (append
   (agent-common-services)
   (paseo-broker-home-services contained-agent #:autostart? #f)
   (paseo-home-services #:desktop? #f)
   (list
    (simple-service 'paseo-cli home-profile-service-type (list paseo))
    (simple-service 'contained-agent home-files-service-type
      (contained-agent-home-files)))))

(define (agent-desktop-services)
  "Return the desktop agent services.  The managed Paseo stack (broker,
daemon service and settings activation) follows %PASEO-SETUP: when it is
#f the Paseo app runs its own daemon on the host and owns its provider
settings."
  (let ((setup (%paseo-setup)))
    (append
     (agent-common-services)
     (if setup
         (append
          (paseo-broker-home-services
           contained-agent
           #:autostart? (paseo-setup-autostart? setup)
           #:requirements (if (home-target-foreign? (current-home-target))
                              '(dbus graphical-session)
                              '(gnome-keyring-secrets))
           #:askpass? #t)
          (paseo-home-services
           #:autostart? (paseo-setup-autostart? setup)))
         '())
     (list
      (simple-service 'llm-desktop-packages
                      home-profile-service-type
                      llm-desktop-packages)
      (simple-service 'contained-agent
                      home-files-service-type
                      (contained-agent-home-files)))
     (my-dotfiles-services (list (project-path "env/dotfiles/llm"))))))
