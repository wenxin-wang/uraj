(define-module (uraj home llm)
  #:use-module (gnu home)
  #:use-module (gnu home services)
  #:use-module (gnu services)
  #:use-module (guix gexp)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module (uraj common basic-services)
  #:use-module (uraj packages codex-desktop)
  #:use-module (uraj packages llm)
  #:use-module (uraj utils file path)
  #:export (home-agent-skills-service-type
            agent-common-services
            agent-desktop-services))

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
headless Paseo container."
  (list
   (simple-service 'llm-agent-packages
                   home-profile-service-type
                   llm-agent-packages)
   (service home-agent-skills-service-type %agent-skills)))

(define llm-desktop-packages
  (list codex-desktop paseo))

(define (agent-desktop-services)
  (append
   (agent-common-services)
   (list
    (simple-service 'llm-desktop-packages
                    home-profile-service-type
                    llm-desktop-packages))
   (my-dotfiles-services (list (project-path "env/dotfiles/llm")))))
