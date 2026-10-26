(define-module (uraj bin contained-agent)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 match)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 regex)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:use-module (srfi srfi-26)
  ;; Only for Paseo's registry; most launches never read it.
  #:autoload (json parser) (json->scm)
  #:use-module (uraj bin contained-ssh)
  #:export (contained-agent-main read-all clause-options codex-spec pi-spec
            credential-clause? credential-options %github-secrets
            %secret-timeout))

;;; Run a coding agent inside `guix shell --container', sharing only the
;;; current project plus the agent's own state.  Arguments, stdio and the
;;; terminal pass straight through, so the same command serves interactive
;;; use and Paseo.  Invoked under an agent's own name (a link named `codex')
;;; it takes exactly that agent's arguments, as Paseo probes
;;; `COMMAND --version' with nothing else; invoked as `contained-agent' the
;;; first argument names the agent.
;;;
;;; Mount rules (later options cover earlier ones):
;;; - The git work tree and the repository's common git directory are
;;;   separate read-write mount points.  hooks/, config, and each linked
;;;   worktree's commondir/gitdir are read-only mount points on top: they make
;;;   host-side git run code or read other files, so the agent must not be
;;;   able to swap them, and a mount point cannot be renamed away (EBUSY).
;;; - Extra per-project clauses come from the projects file, which the
;;;   sandbox cannot see, keyed by the current work tree's canonical root,
;;;   falling back, only when no entry matches, to the checkout Paseo created
;;;   the worktree from (see `paseo-source-root'), then the main work tree:
;;;
;;;     (project "~/src/uraj"
;;;       (expose "/var/log" "~/.local/state/shepherd")
;;;       (share PATH ...)
;;;       (preserve "HF_TOKEN" "WANDB_.*")
;;;       (git-hooks "scripts/hooks"))   ;core.hooksPath inside only
;;;
;;;   and from the project itself: `.guix/contained-agent.scm' holds the same
;;;   mount/environment clauses at top level.  Only central configuration
;;;   may select (manifest ".guix/maa-manifest.scm") and declare
;;;   (ssh-agent (identity PATH (destinations HOST ...)));
;;;   its keys are loaded automatically on the host before entering.  It
;;;   alone may also hand out credentials (see `credential-options'):
;;;     (env NAME (file FILE))       NAME set to the contents of FILE
;;;     (env NAME (value VALUE))     NAME set to VALUE, only in private files
;;;     (github TIER)                git and gh on github.com, TIER being
;;;                                  public, personal or world
;;;     (git-credential URL FILE)    git over HTTPS below URL
;;;   FILE stays on the host or is mounted alone, read-only.
;;;   The local file lives next to `.guix/manifest.scm' (or a top-level
;;;   `manifest.scm'), whose packages join the container's.  Both are written
;;;   by the agent, and the manifest is Scheme that `guix shell' evaluates on
;;;   the host, so they count only once `contained-agent allow' has shown them
;;;   to the user and copied them away; sessions load that copy, chosen by the
;;;   hash of the project's current files.  Changed or unreviewed files are
;;;   left out with a warning.  A worktree takes over the approvals of the
;;;   checkouts its policy would inherit from (see `inherit-approvals') when
;;;   they approved its current local files and .envrc, both at once.
;;; - Files under %denied are never mounted on request.
;;;
;;; Projects files are `read', never evaluated.
;;;
;;; Agents and the mounts common to all of them are data from the caller, an
;;; alist per agent with the keys below (all but `program' optional):
;;;
;;;   program   the real executable
;;;   arguments arguments prepended to the caller's arguments
;;;   share     paths shared read-write when they exist
;;;   expose    paths exposed read-only when they exist
;;;   overlay   exposed directories made writable for the session only,
;;;             through a tmpfs overlay that is dropped on exit, so nothing
;;;             the agent adds, changes or replaces there reaches the host
;;;   persist   paths within `overlay' directories that do reach the host,
;;;             shared read-write and bound back over the overlay (a
;;;             directory, created if missing, if the name ends in /)
;;;   seed      files copied into the container's home, writable but
;;;             dropped on exit
;;;   preserve  regexps of environment variable names to keep

(define (warn fmt . args)
  (apply format (current-error-port)
         (string-append "contained-agent: " fmt "~%") args)
  ;; Before execlp replaces the process.
  (force-output (current-error-port)))

(define (die fmt . args)
  (apply warn fmt args)
  (exit 1))

(define (expand-home file)
  (if (string-prefix? "~/" file)
      (string-append (getenv "HOME") (string-drop file 1))
      file))

(define (mkdir-p dir)
  (unless (file-exists? dir)
    (mkdir-p (dirname dir))
    (catch 'system-error
      (lambda () (mkdir dir))
      (lambda args
        (unless (= EEXIST (system-error-errno args)) (apply throw args))))))

(define (command-lines program . args)
  "Run PROGRAM with ARGS, its stderr discarded; return its stdout lines, or #f
if it fails."
  (let* ((port (with-error-to-port (%make-void-port "w")
                 (cut apply open-pipe* OPEN_READ program args)))
         (lines (let loop ((acc '()))
                  (match (read-line port)
                    ((? eof-object?) (reverse acc))
                    (line (loop (cons line acc)))))))
    (and (zero? (status:exit-val (close-pipe port)))
         lines)))

(define (directory? file)
  (eq? 'directory (and=> (stat file #f) stat:type)))

(define (share file) (list (string-append "--share=" file)))

(define (expose file)
  (if (file-exists? file)
      (list (string-append "--expose=" file))
      '()))

(define (git-mounts git top common gitdir)
  "Mount the work tree TOP and the repository's COMMON git directory, with the
files that host-side git trusts read-only.  GITDIR is TOP's own git directory,
COMMON itself unless TOP is a linked worktree."
  (let ((worktrees (string-append common "/worktrees")))
    (mkdir-p (string-append common "/hooks"))
    (append
     ;; Git lists the main work tree first.
     ;; Mount it before TOP and COMMON so their writable mounts win.
     (if (string=? gitdir common)
         '()
         (match (command-lines git "-C" top "worktree" "list" "--porcelain")
           ((_ "bare" . _) '())
           ((first . _)
            (if (string-prefix? "worktree " first)
                (let ((main (string-drop first (string-length "worktree "))))
                  (if (file-exists? (string-append main "/.git"))
                      ((requested expose "main work tree") main)
                      '()))
                '()))
           (_ '())))
     (share top)
     ;; A linked worktree's .git is a file naming GITDIR.
     (if (directory? (string-append top "/.git"))
         '()
         (expose (string-append top "/.git")))
     (share common)
     (expose (string-append common "/hooks"))
     (expose (string-append common "/config"))
     (if (directory? worktrees)
         (append
          (expose worktrees)
          (if (string=? gitdir common)
              '()
              (append (share gitdir)
                      (expose (string-append gitdir "/commondir"))
                      (expose (string-append gitdir "/gitdir")))))
         '()))))

(define (project-mounts git workdir)
  "Return the project root, used to look up extra clauses, WORKDIR's work
tree, and the mount options for WORKDIR."
  (match (command-lines git "-C" workdir "rev-parse" "--path-format=absolute"
                        "--show-toplevel" "--git-common-dir" "--git-dir")
    ((top common gitdir)
     (values top
             top
             (git-mounts git top common gitdir)))
    (_
     (values workdir workdir (share workdir)))))

;;; Requested mounts.

(define %denied
  ;; Credentials, Paseo's keys (control of every session), our own
  ;; configuration and approvals, the build daemon (use the explicit
  ;; guix-daemon clause instead), decrypted SOPS secrets (use the explicit
  ;; credential clauses instead), the user's service managers, and Podman
  ;; runtime state: the host service's socket runs any container as the user.
  '("~/.paseo" "~/.paseo-password" "~/.ssh" "~/.gnupg" "~/.password-store"
    "~/.config/contained-agent" "~/.local/state/contained-agent"
    "~/.local/share/contained-agent"
    "~/.local/state/paseo-broker"
    "~/.config/paseo" "~/.local/state/paseo-sandbox"
    "~/.cache/contained-agent"
    "/var/guix/daemon-socket" "/run/secrets" "/run/user"
    "/run/contained-podman"))

(define (resolve file)
  (if (file-exists? file) (canonicalize-path file) file))

(define (within? file dir)
  (or (string=? file dir)
      (string-prefix? (string-append dir "/") file)))

(define (denied? file)
  "Whether FILE is denied or contains a denied file, as $HOME and / do."
  (let ((file (resolve file)))
    (any (lambda (denied)
           (let ((denied (resolve (expand-home denied))))
             (or (within? file denied) (within? denied file))))
         %denied)))

(define (requested mount origin)
  (lambda (file)
    (let ((file (expand-home file)))
      (cond ((denied? file)
             (warn "~a: never mounting ~a" origin file)
             '())
            ((file-exists? file) (mount file))
            (else '())))))

(define (mount-path file project origin)
  "Expand FILE relative to PROJECT, including for inherited policies."
  (when (or (string-null? file) (string-contains file "="))
    (die "~a: invalid mount path ~s" origin file))
  (let ((file (expand-home file)))
    (if (absolute-file-name? file)
        file
        (string-append (or project (getcwd)) "/" file))))

(define (mount-check-path file)
  "Resolve existing ancestors as well as dot components of missing targets."
  (cond ((file-exists? file) (canonicalize-path file))
        ((string=? (basename file) ".") (mount-check-path (dirname file)))
        ((string=? (basename file) "..")
         (dirname (mount-check-path (dirname file))))
        (else (string-append (string-trim-right
                             (mount-check-path (dirname file)) #\/)
                            "/" (basename file)))))

(define (requested-mapping mount origin project)
  (lambda (entry)
    (match entry
      ((? string? file)
       ((requested mount origin) (mount-path file project origin)))
      (((? string? source) (? string? target))
       (let ((source (mount-path source project origin))
             (target (mount-path target project origin)))
         (cond ((or (denied? (mount-check-path source))
                    (denied? (mount-check-path target)))
                (warn "~a: never mounting ~a at ~a" origin source target)
                '())
               ((file-exists? source)
                ;; expose checks existence, so apply it before adding TARGET.
                (map (cut string-append <> "=" target) (mount source)))
               (else '()))))
      (_ (die "~a: bad mount entry ~s" origin entry)))))

(define* (clause-options origin clause #:optional project)
  (match clause
    ;; Applied after ordinary mappings so cache/GC-root mounts take priority.
    (('guix-daemon) '())
    ;; Written to the session's ~/.gitconfig, see `git-hooks'.
    (('git-hooks (? string?)) '())
    (('expose files ...)
     (append-map (requested-mapping expose origin project) files))
    (('share files ...)
     (append-map (requested-mapping share origin project) files))
    ;; Host environment variables, by name regexp, passed when set.
    (('preserve (? string? names) ...)
     (map (cut string-append "--preserve=^" <> "$") names))
    (_ (die "~a: bad clause ~s" origin clause))))

(define (podman-remote-policy clauses)
  "Parse the central permission and optional host-visible temporary directory."
  (match (filter (lambda (x)
                   (and (pair? x) (eq? (car x) 'podman-remote))) clauses)
    (() #f)
    ((('podman-remote)) '())
    ((('podman-remote ('tmpdir (? string? path))))
     (let ((path (expand-home path)))
       (unless (string-prefix? "/" path)
         (die "podman-remote: TMPDIR must be absolute or start with ~/: ~a" path))
       (when (any (lambda (part) (member part '("." "..")))
                  (string-split path #\/))
         (die "podman-remote: TMPDIR must not contain . or .. components"))
       `((tmpdir . ,path))))
    (_ (die "expected one central (podman-remote [(tmpdir PATH)]) clause"))))

(define (podman-remote-mounts policy)
  (let ((tmpdir (and policy (assq-ref policy 'tmpdir))))
    (if tmpdir
        (begin
          ;; Validate before creating anything on the host.  Canonicalize after
          ;; creation as well, so symlink ancestors cannot bypass the denylist.
          (when (denied? tmpdir) (die "podman-remote: denied TMPDIR ~a" tmpdir))
          (let loop ((parent tmpdir) (suffix ""))
            (if (file-exists? parent)
                (when (denied? (string-append (canonicalize-path parent) suffix))
                  (die "podman-remote: denied TMPDIR parent ~a" parent))
                (loop (dirname parent)
                      (string-append "/" (basename parent) suffix))))
          (mkdir-p tmpdir)
          (unless (directory? tmpdir)
            (die "podman-remote: TMPDIR is not a directory: ~a" tmpdir))
          (when (denied? tmpdir) (die "podman-remote: denied TMPDIR ~a" tmpdir))
          (share tmpdir))
        '())))

(define %podman-launcher (make-parameter #f))

(define %podman-remote-setup
  ;; Local API socket belongs to this session's isolated runtime.
  ;; Keep the wrapper after direnv initialization and overlay setup.
  "set -eu
tmpdir=$1; shift
if [ -n \"$tmpdir\" ]; then export TMPDIR=$tmpdir; fi
real=$(command -v podman) || { echo 'podman-remote requires podman in the manifest' >&2; exit 1; }
d=$HOME/.local/share/contained-agent/podman-remote
mkdir -p \"$d\"
export CONTAINER_HOST=unix:///run/contained-agent/podman/podman.sock
export DOCKER_HOST=$CONTAINER_HOST
unset CONTAINER_CONNECTION CONTAINER_SSHKEY
unset DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH
export CONTAINED_AGENT_PODMAN=$real
cat > \"$d/podman\" <<'EOF'
#!/bin/sh
exec \"$CONTAINED_AGENT_PODMAN\" --remote \"$@\"
EOF
chmod 700 \"$d/podman\"
export PATH=$d:$PATH
exec \"$@\"")

(define (read-all file)
  (call-with-input-file file
    (lambda (port)
      (let loop ((acc '()))
        (match (read port)
          ((? eof-object?) (reverse acc))
          (form (loop (cons form acc))))))))

(define %secret-timeout
  ;; Seconds to wait for a file SOPS decrypts: agents and Paseo may start
  ;; at boot before SOPS is done.
  (make-parameter 10))

(define (wait-for-secret origin file)
  "Wait for FILE, a secret this host declares, and fail if it does not
appear in time rather than start without it."
  (let loop ((polls (* 5 (%secret-timeout))))
    (unless (file-exists? file)
      (when (<= polls 0)
        ;; Caught like SSH failures: the broker's ssh-service replies with
        ;; it and keeps serving.
        (throw 'contained-ssh-error
               (format #f "~a: ~a is still missing after ~a s; \
check `sudo herd status sops-secrets'"
                       origin file (%secret-timeout))))
      (usleep 200000)
      (loop (- polls 1)))))

(define %projects-secret
  ;; The host-private projects file SOPS decrypts, or #f if this host has
  ;; none.
  (make-parameter #f))

(define (paseo-records name)
  "Return the records in Paseo's registry file NAME, or '() if unreadable."
  (let ((file (string-append (or (getenv "PASEO_HOME") (expand-home "~/.paseo"))
                             "/projects/" name)))
    (if (file-exists? file)
        (catch #t
          (lambda ()
            (match (call-with-input-file file json->scm)
              (#((? pair? records) ...) records)
              (_ (warn "~a: unexpected format, ignored" file) '())))
          (lambda _
            (warn "~a: unreadable, ignored" file)
            '()))
        '())))

(define (paseo-source-root project common git)
  "Return the root of the checkout Paseo created the worktree PROJECT from, if
it is another work tree of the repository whose git directory is COMMON, or
#f.  Paseo's registry is outside every container, so agents cannot choose
it; Paseo itself could already start them in that checkout."
  (define (active? record)
    (member (assoc-ref record "archivedAt") '(#f null)))
  (let ((ids (delete-duplicates
              (filter-map
               (lambda (record)
                 (and (active? record)
                      (equal? (assoc-ref record "kind") "worktree")
                      (string? (assoc-ref record "worktreeRoot"))
                      (string=? (resolve (assoc-ref record "worktreeRoot"))
                                (resolve project))
                      (assoc-ref record "projectId")))
               (paseo-records "workspaces.json")))))
    (match ids
      (((? string? id))
       (match (filter (lambda (record)
                        (and (active? record)
                             (equal? (assoc-ref record "projectId") id)
                             (string? (assoc-ref record "rootPath"))))
                      (paseo-records "projects.json"))
         ((record)
          (match (command-lines git "-C" (assoc-ref record "rootPath")
                                "rev-parse" "--path-format=absolute"
                                "--show-toplevel" "--git-common-dir")
            ((top source-common)
             (and (string=? (resolve source-common) (resolve common))
                  (resolve top)))
            (_ #f)))
         (_ #f)))
      (_ #f))))

(define (source-checkouts project git)
  "Return the checkouts PROJECT inherits from, in order: the one Paseo created
it from, then the main work tree."
  (match (command-lines git "-C" project "rev-parse"
                        "--path-format=absolute" "--git-common-dir")
    ((common)
     (filter-map identity
                 (list (paseo-source-root project common git)
                       (and (string-suffix? "/.git" common)
                            (resolve (dirname common))))))
    (_ '())))

(define (central-entries file project git)
  "Use PROJECT's central entries, or else those of the checkout Paseo created
it from, or else the main work tree's.  An explicit empty entry suppresses
inheritance across all policy sources."
  (let ((secret (%projects-secret)))
    (when secret (wait-for-secret "contained-agent" secret))
    (let* ((sources
            (delete-duplicates
             (filter-map
              identity
              (list (expand-home (or (getenv "CONTAINED_AGENT_PROJECTS") file))
                    secret
                    (expand-home "~/.config/contained-agent/projects.local.scm")))))
           (entries
            (append-map
             (lambda (source)
               (if (file-exists? source)
                   (map (match-lambda
                          (('project (? string? root) clauses ...)
                           (list (resolve (expand-home root)) source clauses))
                          (form (die "~a: bad entry ~s" source form)))
                        (read-all source))
                   '()))
             sources))
           (entries-of (lambda (root)
                         (filter (lambda (entry)
                                   (string=? (car entry) (resolve root)))
                                 entries)))
           (own (entries-of project))
           (selected
            (if (pair? own)
                own
                (or (find pair? (map entries-of
                                     (source-checkouts project git)))
                    '()))))
      (append-map
       (match-lambda
         ((root source clauses) (map (cut cons source <>) clauses)))
       selected))))

(define (git-hooks clauses)
  "Return the DIR of the (git-hooks DIR) clause among CLAUSES, (ORIGIN .
CLAUSE) pairs, or #f.  It becomes core.hooksPath in the session's own
~/.gitconfig: .git/hooks is read-only in the container, and a relative DIR
names hooks in each work tree."
  (match (filter-map (match-lambda
                       ((_ . ('git-hooks (? string? directory))) directory)
                       (_ #f))
                     clauses)
    (() #f)
    ((directory) directory)
    (_ (die "expected a single (git-hooks DIR) clause"))))

;;; Credentials from host files.

(define %github-secrets
  ;; Where SOPS decrypts the token of each tier, see secrets/README.org, or
  ;; #f if this host has no tokens.
  (make-parameter "/run/secrets/github"))

(define %github-tiers '("public" "personal" "world"))

(define (credential-clause? entry)
  (match entry
    ((origin . ((or 'env 'github 'git-credential) _ ...)) #t)
    (_ #f)))

(define (read-secret origin file what)
  "Return the trimmed contents of FILE, or #f with a warning if it is missing,
unreadable or empty."
  (let ((value (false-if-exception
                (string-trim-both (call-with-input-file file read-string)))))
    (cond ((not value)
           (warn "~a: cannot read ~a; starting without ~a" origin file what)
           #f)
          ((string-null? value)
           (warn "~a: ~a is empty; starting without ~a" origin file what)
           #f)
          (else value))))

(define (git-credential-helper file)
  "A helper answering `get' with the token in FILE, ignoring `store' and
`erase': FILE is read-only."
  ;; Shell builtins only: PATH may lack coreutils.
  (string-append "!f() { test \"$1\" = get || exit 0; "
                 "IFS= read -r t < " file " || test -n \"$t\"; "
                 "echo username=x-access-token; "
                 "printf 'password=%s\\n' \"$t\"; }; f"))

(define* (credential-options entries directory #:key (private? (const #t)))
  "Apply the central credential clauses among ENTRIES, (ORIGIN . CLAUSE)
pairs, and return the `guix shell' options that hand them to the container.
Values travel in the environment or in files mounted alone under DIRECTORY,
never on a command line.  (env NAME (value VALUE)) is accepted only from an
ORIGIN satisfying PRIVATE?: other files may reach the store or Git.  A
missing, unreadable or empty file is skipped with a warning, and the host's
own value never stands in for it; but the token of a (github TIER) clause
is a SOPS secret, waited for and required on hosts that have the tokens.

Git configuration goes through GIT_CONFIG_COUNT, after the global file the
agent may edit: an empty credential.helper first drops every helper of
the host's configuration, such as `gh auth setup-git''s, then each URL gets
a helper reading its token.  git asks helpers in order, so git-credential
clauses, usually narrower, come before the github tier.  The gh in the
container asks git for the current repository's token."
  (define (variable name)
    (unless (string-match "^[A-Za-z_][A-Za-z0-9_]*$" name)
      (die "bad variable name ~s" name))
    name)
  (define (pass name value)
    (unsetenv name)
    (if value
        (begin
          (setenv name value)
          (list (string-append "--preserve=^" name "$")))
        '()))
  (define clauses (filter credential-clause? entries))
  (define environment
    (append-map
     (match-lambda
       ((origin . ('env (? string? name) ('file (? string? file))))
        (let ((name (variable name)))
          (pass name (read-secret origin (expand-home file) name))))
       ((origin . ('env (? string? name) ('value (? string? value))))
        (unless (private? origin)
          (die "~a: (env ~s (value ...)) belongs in a private file; \
use (file FILE) here" origin name))
        (pass (variable name) value))
       ((origin . ('env _ ...))
        (die "~a: expected (env NAME (file FILE)) or (env NAME (value VALUE))"
             origin))
       (_ '()))
     clauses))
  (define credentials                   ;(ORIGIN URL FILE), in order
    (append
     (filter-map
      (match-lambda
        ((origin . ('git-credential (? string? url) (? string? file)))
         (unless (and (string-prefix? "https://" url)
                      (not (string-any char-whitespace? url)))
           (die "~a: git-credential needs an https:// URL: ~s" origin url))
         (list origin url (expand-home file)))
        ((origin . ('git-credential _ ...))
         (die "~a: expected (git-credential URL FILE)" origin))
        (_ #f))
      clauses)
     (match (filter (match-lambda ((_ . ('github _ ...)) #t) (_ #f)) clauses)
       (() '())
       (((origin . ('github (? string? tier))))
        (unless (member tier %github-tiers)
          (die "~a: unknown GitHub tier ~s, expected one of ~a"
               origin tier (string-join %github-tiers ", ")))
        (match (%github-secrets)
          (#f
           (warn "~a: no GitHub tokens on this host; starting without ~a"
                 origin "https://github.com")
           '())
          (directory
           (let ((file (string-append directory "/" tier)))
             (wait-for-secret origin file)
             (list (list origin "https://github.com" file))))))
       (((origin . clause) . rest)
        (die "~a: expected a single (github TIER) clause, got ~s"
             origin clause)))))
  (define mounted                       ;((URL . TARGET) . OPTION) ...
    (filter-map
     (lambda (credential index)
       (match credential
         ((origin url file)
          (and (read-secret origin file url)
               (let ((target (string-append directory "/git-credential-"
                                            (number->string index))))
                 (cons (cons url target)
                       (string-append "--expose=" file "=" target)))))))
     credentials (iota (length credentials))))
  (define config
    (append
     '(("credential.helper" . ""))
     (map (match-lambda
            (((url . target) . _)
             (cons (string-append "credential." url ".helper")
                   (git-credential-helper target))))
          mounted)))
  (setenv "GIT_CONFIG_COUNT" (number->string (length config)))
  (for-each (lambda (entry index)
              (let ((index (number->string index)))
                (setenv (string-append "GIT_CONFIG_KEY_" index) (car entry))
                (setenv (string-append "GIT_CONFIG_VALUE_" index) (cdr entry))))
            config (iota (length config)))
  (append environment
          (map cdr mounted)
          '("--preserve=^GIT_CONFIG_(COUNT|KEY_[0-9]+|VALUE_[0-9]+)$")))

;;; Optional Guix daemon access.

(define (guix-project-cache project host-cache)
  "Seed an independent project cache once, never copying it back to HOST-CACHE."
  (let* ((base (string-append (expand-home "~/.cache/contained-agent/guix")
                              (canonicalize-path project)))
         (cache (string-append base "/cache")))
    (mkdir-p base)
    (let ((lock (open-file (string-append base "/seed.lock") "a")))
      (dynamic-wind
        (lambda () (flock lock LOCK_EX))
        (lambda ()
          (unless (directory? cache)
            (let ((staging (mkdtemp (string-append base "/seed-XXXXXX"))))
              (catch #t
                (lambda ()
                  (when (directory? host-cache)
                    (unless (zero? (system* "cp" "-a" "--reflink=auto" "--"
                                            (string-append host-cache "/.") staging))
                      (error "cannot seed project Guix cache")))
                  (rename-file staging cache))
                (lambda (key . args)
                  (system* "rm" "-rf" "--" staging)
                  (apply throw key args))))))
        (lambda () (flock lock LOCK_UN) (close-port lock))))
    cache))

(define* (guix-daemon-options project
                              #:key
                              (profile-directory
                               (string-append "/var/guix/profiles/per-user/"
                                              (or (getenv "USER") (getenv "LOGNAME")
                                                  (passwd:name (getpwuid (getuid)))))))
  "Enable nesting, then cover its host cache and restore writable GC roots."
  (let* ((default-cache (expand-home "~/.cache/guix"))
         (host-cache (string-append (or (getenv "XDG_CACHE_HOME")
                                       (expand-home "~/.cache")) "/guix"))
         (cache (guix-project-cache project host-cache))
         (roots (map (cut string-append profile-directory "/" <>)
                     '("profiles" "inferiors"))))
    (for-each mkdir-p roots)
    (append
     '("--nesting" "--preserve=^GUIX_DAEMON_SOCKET$")
     ;; Guix mounts its nesting mappings before all user mappings.  Cover
     ;; both the host XDG location and the container's default cache path.
     (map (lambda (target) (string-append "--share=" cache "=" target))
          (delete-duplicates (list host-cache default-cache)))
     (append-map share roots))))

;;; Project-local files and their approval.

(define (state-directory . parts)
  (string-join (cons (string-append (getenv "HOME")
                                    "/.local/state/contained-agent")
                     parts)
               "/"))

(define (project-key project)
  (string-concatenate
   (map (lambda (c)
          (case c
            ((#\%) "%25")
            ((#\/) "%2F")
            (else (string c))))
        (string->list project))))

(define (project-manifest central)
  "Return the manifest selected by central policy, relative to the work tree."
  (match (filter-map (match-lambda
                       ((_ . ('manifest (? string? file))) file)
                       ((_ . ('manifest args ...))
                        (die "expected (manifest RELATIVE-FILE)"))
                       (_ #f))
                     central)
    (() #f)
    ((file)
     (when (any (cut member <> '("" "." "..")) (string-split file #\/))
       (die "manifest must be a relative work tree path: ~a" file))
     file)
    (_ (die "expected a single (manifest RELATIVE-FILE) clause"))))

(define (check-manifest top manifest)
  "Require MANIFEST to name a regular file without symlink components."
  (let loop ((path top) (parts (string-split manifest #\/)))
    (let* ((file (string-append path "/" (car parts)))
           (type (and=> (false-if-exception (lstat file)) stat:type)))
      (unless (eq? type (if (null? (cdr parts)) 'regular 'directory))
        (die "manifest path is missing or has an invalid file type: ~a" file))
      (unless (null? (cdr parts)) (loop file (cdr parts))))))

(define (local-files top manifest)
  "Return the name of work tree TOP's project-local files, `.guix' or
the selected manifest, or #f."
  (if manifest
      (begin
        (check-manifest top manifest)
        (if (string-prefix? ".guix/" manifest) ".guix" manifest))
      (find (lambda (name)
              (file-exists? (string-append top "/" name)))
            '(".guix" "manifest.scm"))))

(define (approved-manifest-name manifest)
  (if (and manifest (string-prefix? ".guix/" manifest))
      (substring manifest (string-length ".guix/"))
      "manifest.scm"))

(define (nar-hash file)
  (match (command-lines "guix" "hash" "--serializer=nar" file)
    ((hash) hash)
    (_ (die "cannot hash ~a" file))))

(define (copy-local source target)
  "Copy SOURCE to TARGET, preserving directory contents or naming a single
file manifest.scm.  Links could reach files nobody
reviewed, so refuse them."
  (define (copy from to)
    (match (stat:type (lstat from))
      ('regular (copy-file from to))
      ('directory
       (mkdir to)
       (for-each (lambda (name)
                   (copy (string-append from "/" name)
                         (string-append to "/" name)))
                 (scandir from (negate (cut member <> '("." ".."))))))
      (type (die "~a: refusing ~a file" from type))))
  (if (directory? source)
      (copy source target)
      (begin
        (mkdir target)
        (copy source (string-append target "/manifest.scm")))))

(define (approved-local top manifest)
  "Return the approved copy of work tree TOP's project-local files, or #f."
  (match (local-files top manifest)
    (#f #f)
    (name
     (let* ((source (string-append top "/" name))
            (copy (state-directory "approved" (project-key top)
                                   (nar-hash source))))
       (if (file-exists? copy)
           copy
           (begin
             (warn "~a is new or changed since `contained-agent allow ~a'; \
starting without it" source top)
             #f))))))

(define (allow directory git projects-file)
  "Show the project-local files of DIRECTORY's work tree against the last
approved ones and, once the user agrees, approve them."
  (let*-values (((project top _)
                 (project-mounts git (canonicalize-path directory)))
                ((manifest) (project-manifest
                             (central-entries projects-file project git)))
                ((name) (or (local-files top manifest)
                            (die "~a has neither .guix nor manifest.scm" top)))
                ((source) (string-append top "/" name))
                ((latest) (state-directory "projects" (project-key project)))
                ((staging) (state-directory
                            (string-append "staging-"
                                           (number->string (getpid))))))
    (mkdir-p (state-directory "approved" (project-key top)))
    (mkdir-p (state-directory "projects"))
    ;; Review and keep a copy: the work tree may change meanwhile.  Its hash
    ;; equals that of SOURCE as long as they are identical.
    (copy-local source staging)
    (let* ((hash (nar-hash (string-append staging
                                          (if (directory? source)
                                              ""
                                              "/manifest.scm"))))
           (target (state-directory "approved" (project-key top) hash)))
      (unless (file-exists? latest)
        (mkdir-p (state-directory "empty")))
      (system* "git" "--no-pager" "diff" "--no-index" "--"
               (if (file-exists? latest) latest (state-directory "empty"))
               staging)
      (unless (isatty? (current-input-port))
        (system* "rm" "-rf" staging)
        (die "approving needs a terminal"))
      (when manifest (format #t "Selected manifest: ~a~%" manifest))
      (format #t "Allow ~a for ~a? [y/N] " source project)
      (force-output)
      (if (member (read-line) '("y" "Y" "yes"))
          (begin
            (if (file-exists? target)
                (system* "rm" "-rf" staging)
                (rename-file staging target))
            (false-if-exception (delete-file latest))
            (symlink target latest)
            (format #t "Allowed as ~a~%" target))
          (begin
            (system* "rm" "-rf" staging)
            (die "not allowed"))))))

;;; direnv approvals.

(define (direnv-allow-name tools envrc contents)
  "Return the name direnv gives its approval of ENVRC, an absolute file name,
holding the contents of the file CONTENTS: the SHA-256 of ENVRC, a newline
and those contents."
  (define (tool name) (or (assq-ref tools name) (symbol->string name)))
  (match (command-lines (tool 'bash) "-c"
                        "{ printf '%s\\n' \"$1\" && cat -- \"$2\"; } | \"$3\""
                        "direnv-allow-name" envrc contents (tool 'sha256sum))
    ((line) (string-take line 64))
    (_ (die "cannot hash ~a" contents))))

(define (direnv-allow-directory)
  (string-append (match (getenv "XDG_DATA_HOME")
                   ((or #f "") (expand-home "~/.local/share"))
                   (data data))
                 "/direnv/allow/"))

(define (envrc? top)
  (eq? 'regular (and=> (stat (string-append top "/.envrc") #f) stat:type)))

(define (direnv-allowed top tools)
  "Return TOP's direnv approval only when the host approved this exact path."
  (let ((envrc (string-append top "/.envrc")))
    (and (envrc? top)
         (let ((name (direnv-allow-name tools envrc envrc)))
           (and (file-exists? (string-append (direnv-allow-directory) name))
                name)))))

;;; Approvals inherited by new worktrees.

(define (inherit-approvals top manifest git tools)
  "Approve work tree TOP's local files and .envrc, both or neither, when a
checkout it inherits from (see `source-checkouts') approved the same contents
at its own path.  Return #t if TOP needs nothing, else the source or #f."
  (let* ((name (local-files top manifest))
         (hash (and name (nar-hash (string-append top "/" name))))
         (envrc (string-append top "/.envrc"))
         (approved (lambda (root)
                     (and hash (state-directory "approved" (project-key root)
                                                hash))))
         (allowed (lambda (root)
                    (and (envrc? top)
                         (string-append
                          (direnv-allow-directory)
                          (direnv-allow-name tools
                                             (string-append root "/.envrc")
                                             envrc)))))
         (approved? (lambda (root)
                      (every (lambda (file) (or (not file) (file-exists? file)))
                             (list (approved root) (allowed root))))))
    (or (approved? top)
        (match (find (lambda (source)
                       (and (not (string=? source top)) (approved? source)))
                     (source-checkouts top git))
          (#f #f)
          (source
           ;; A link is created atomically, and approved copies never change.
           (when (and hash (not (file-exists? (approved top))))
             (mkdir-p (dirname (approved top)))
             (symlink (approved source) (approved top)))
           (when (allowed top)
             (mkdir-p (direnv-allow-directory))
             (call-with-output-file (allowed top)
               (cut format <> "~a~%" envrc)))
           source)))))

(define (inherit directory git projects-file tools)
  (let*-values (((project top _)
                 (project-mounts git (canonicalize-path directory))))
    (match (inherit-approvals
            top (project-manifest (central-entries projects-file project git))
            git tools)
      (#t (format #t "~a needs no approvals~%" top))
      (#f (die "~a: no checkout it inherits from approved its local files and \
.envrc as they are; run `contained-agent allow' and `direnv allow'" top))
      (source (format #t "Inherited approvals of ~a~%" source)))))

;;; Agents.

(define (spec-ref spec key)
  (map expand-home (or (assq-ref spec key) '())))

(define (codex-spec program)
  "Return Codex's mounts, keeping configuration private to each session."
  (let* ((home (expand-home "~/.codex"))
         (sqlite (string-append home "/contained-sqlite")))
    (when (and (getenv "CODEX_HOME")
               (not (string=? (getenv "CODEX_HOME") home)))
      (die "contained Codex requires CODEX_HOME=~a" home))
    (mkdir-p home)
    (unless (file-exists? (string-append sqlite "/state_5.sqlite"))
      (warn "Codex: first startup indexes existing sessions; let it finish")
      (warn "interrupting backfill can block retries for 15 minutes"))
    ;; Create the history mount target without truncating an existing file,
    ;; including when two launchers start together.
    (catch 'system-error
      (lambda ()
        (close-port (open (string-append home "/history.jsonl")
                          (logior O_WRONLY O_CREAT O_EXCL) #o600)))
      (lambda args
        (unless (= EEXIST (system-error-errno args)) (apply throw args))))
    (unless (file-exists? (string-append home "/auth.json"))
      (warn "Codex: no host auth.json; new logins will be session-only"))
    `((program . ,program)
      (arguments "-c" ,(string-append "sqlite_home="
                                     (format #f "~s" sqlite)))
      (overlay "~/.codex" "~/.agents/skills")
      ;; auth is rewritten in place; session_index is atomically replaced
      ;; when a thread is deleted and must not be a single-file mount.
      (persist "~/.codex/contained-sqlite/" "~/.codex/sqlite/"
               "~/.codex/sessions/" "~/.codex/archived_sessions/"
               "~/.codex/thread-writer-locks/" "~/.codex/log/"
               "~/.codex/auth.json" "~/.codex/history.jsonl")
      (preserve "CODEX_.*" "OPENAI_.*"))))

(define (pi-spec program)
  "Persist Pi's settings and sessions, leaving other agent files temporary."
  (let ((settings (expand-home "~/.pi/agent/settings.json")))
    (mkdir-p (dirname settings))
    ;; persist only mounts existing files.  O_EXCL keeps existing settings
    ;; intact and lets concurrent first launches create the file safely.
    ;; Pi writes settings in place, so a file bind mount is sufficient.
    (catch 'system-error
      (lambda ()
        (let ((port (open settings (logior O_WRONLY O_CREAT O_EXCL) #o600)))
          (display "{}\n" port)
          (close-port port)))
      (lambda args
        (unless (= EEXIST (system-error-errno args)) (apply throw args))))
    `((program . ,program)
      (overlay "~/.pi/agent" "~/.agents/skills")
      (persist "~/.pi/agent/sessions/" "~/.pi/agent/settings.json")
      (preserve "OPENAI_.*" "ANTHROPIC_.*" "GEMINI_API_KEY"
                "OPENROUTER_API_KEY"))))

(define (persisted spec)
  "Return the existing `persist' paths of SPEC, creating directories."
  (filter-map (lambda (file)
                (if (string-suffix? "/" file)
                    (let ((dir (string-drop-right file 1)))
                      (mkdir-p dir)
                      dir)
                    (and (file-exists? file) file)))
              (spec-ref spec 'persist)))

(define (side-target kind)
  ;; Where the container sees a file before it is moved into place: an
  ;; overlay's lower directory must hold no mount points.
  (lambda (index)
    (string-append "/run/contained-agent/" kind "-" (number->string index))))

(define (seeds spec)
  "Return SPEC's existing `seed' files."
  (filter file-exists? (spec-ref spec 'seed)))

(define (spec-mounts spec)
  "Return the `guix shell' options for SPEC's mounts."
  (append
   (append-map (lambda (file)
                 (if (file-exists? file) (share file) '()))
               (spec-ref spec 'share))
   (append-map expose (spec-ref spec 'expose))
   ;; Overlays are mounted within the container, over what is exposed.
   (append-map expose (spec-ref spec 'overlay))))

(define (spec-overlay spec)
  "Return the bubblewrap options that overlay SPEC's `overlay' directories,
applied inside the container."
  (append-map (lambda (dir)
                (if (directory? dir)
                    (list "--overlay-src" dir "--tmp-overlay" dir)
                    '()))
              (spec-ref spec 'overlay)))

(define (spec-preserve spec)
  (map (cut string-append "--preserve=^" <> "$")
       (or (assq-ref spec 'preserve) '())))

(define (program-name file)
  "Return the name FILE was invoked as, without the hash of a store item."
  (let ((name (basename file)))
    (match (string-match "^[0-9a-df-np-sv-z]{32}-(.+)$" name)
      (#f name)
      (m (match:substring m 1)))))

(define (working-directory)
  ;; Paseo spawns agents from its own working directory, $HOME, and names the
  ;; session's in PASEO_AGENT_CWD.  Every process below an agent inherits
  ;; that variable, so trust it only in that situation.
  (let ((cwd (getcwd))
        (paseo (getenv "PASEO_AGENT_CWD")))
    (canonicalize-path
     (if (and paseo (string=? cwd (getenv "HOME")))
         paseo
         cwd))))

(define (serve-project-ssh git projects-file ssh-tools)
  "Prepare project SSH in one broker-owned namespace shared across sessions.
Requests are NUL-terminated working directories; replies are STATUS NUL TEXT
NUL.  All ssh-add output goes to stderr, never into this private protocol."
  (define (reply status text)
    (display status) (write-char #\nul)
    (display text) (write-char #\nul)
    (force-output))
  (unless (getenv "CONTAINED_AGENT_SSH_RUNTIME_DIRECTORY")
    (die "ssh-service requires a broker-owned runtime directory"))
  (let loop ()
    (let ((directory (read-delimited (string #\nul))))
      (unless (eof-object? directory)
        (catch 'contained-ssh-error
          (lambda ()
            (let*-values
                (((project top mounts) (project-mounts git directory))
                 ((policy) (ssh-policy
                            (map cdr (central-entries
                                      (expand-home projects-file) project git)))))
              (when policy (ssh-ensure project policy ssh-tools))
              (reply "ok" "")))
          (lambda (_ message) (reply "error" message)))
        (loop)))))

(define (run-agent name args agents common packages git projects-file ssh-tools)
  (let* ((spec (or (assoc-ref agents name)
                  (die "unknown agent ~a" name)))
         (program (assq-ref spec 'program)))
    ;; Paseo gives --version only five seconds and caches a failed probe as
    ;; unsupported features. This exact invocation needs no project policy,
    ;; credentials, overlays or Guix profile; run the configured binary.
    ;; All other arguments, including auth status, still use the container.
    (if (equal? args '("--version"))
        (execl program program "--version")
        (run-agent-container spec args common packages git projects-file
                             ssh-tools))))

(define (run-agent-container spec args common packages git projects-file ssh-tools)
  (let*-values
      (((home) (getenv "HOME"))
       ((workdir) (working-directory))
       ((project top mounts)
        ;; Paseo's helper app-servers (model lists etc.) and stray launches
        ;; from $HOME get an empty home instead of the whole of it.
        (if (member workdir (list home "/"))
            (values #f #f '())
            (project-mounts git workdir)))
       ((projects-file) (expand-home (or (getenv "CONTAINED_AGENT_PROJECTS")
                                         projects-file)))
       ((central) (if project (central-entries projects-file project git) '()))
       ((manifest) (project-manifest central))
       ((local) (and top
                     (begin
                       (inherit-approvals top manifest git ssh-tools)
                       (approved-local top manifest))))
       ((direnv) (and top (direnv-allowed top ssh-tools)))
       ((local-file) (lambda (name)
                       (let ((file (and local (string-append local "/" name))))
                         (and file (file-exists? file) file))))
       ((ssh) (ssh-policy (map cdr central)))
       ;; Version probes must not depend on SSH provisioning.
       ((ssh-dir) (and ssh (not (member args '(("--version") ("auth" "status"))))
                       (if (getenv "CONTAINED_AGENT_SSH_PREPARED")
                           (ssh-prepared-directory project ssh ssh-tools)
                           (ssh-ensure project ssh ssh-tools))))
       ;; After every host-side use of the environment, such as SSH askpass.
       ;; The Home-managed projects file is public: in Git and the store.
       ((credentials) (credential-options
                       central "/run/contained-agent"
                       #:private? (lambda (origin)
                                    (not (string=? origin projects-file)))))
       ((clauses)
        ;; (ORIGIN . CLAUSE), ORIGIN naming the file for messages.
        (append
         (remove (match-lambda
                   ((origin . clause)
                    (or (credential-clause? (cons origin clause))
                        (and (pair? clause)
                             (memq (car clause) '(ssh-agent manifest podman-remote))))))
                 central)
         (match (local-file "contained-agent.scm")
           (#f '())
           (file (map (cut cons (string-append top "/.guix/contained-agent.scm")
                           <>)
                      (read-all file)))))))
    (define (aside files kind)
      ;; (FILE . SIDE-TARGET) for each of FILES.
      (map cons files (map (side-target kind) (iota (length files)))))
    (define seeded                      ;copied into place
      (aside (append (seeds spec) (seeds common)) "seed"))
    (define kept                        ;bound back over the overlays
      (aside (append (persisted spec) (persisted common)) "persist"))
    (define podman?
      (and (not (member args '(("--version") ("auth" "status"))))
           (podman-remote-policy (map cdr central))))
    (define podman-tmp (podman-remote-mounts podman?))
    (define project-options
      (append-map (match-lambda
                    ((origin . clause) (clause-options origin clause))) clauses))
    (define launch
      (if podman?
          (begin
            (unless (%podman-launcher)
              (die "podman-remote: host runtime launcher is not configured"))
            (append (%podman-launcher)
                    (list "--project" project)
                    (map (cut string-append "--mount-option=" <>)
                         (filter (lambda (option)
                                   (or (string-prefix? "--share=" option)
                                       (string-prefix? "--expose=" option)))
                                 (append mounts project-options podman-tmp)))
                    '("--" "guix")))
          '("guix")))
    (apply execlp (car launch) (car launch)
           (append (cdr launch) (list "shell"
           "--container" "--no-cwd" "--network" "--expose=/gnu/store"
           ;; Shebangs written for other systems, as Guix System has it.
           "--symlink=/usr/bin/env=bin/env")
           (append
            ;; Broad common mounts (such as read-only ~/src) must precede
            ;; the writable work tree and its nested Git protections.
            (spec-mounts common)
            mounts
            (spec-mounts spec)
            (map (match-lambda
                   ((source . target)
                    (string-append "--expose=" source "=" target)))
                 seeded)
            (map (match-lambda
                   ((file . target)
                    (string-append "--share=" file "=" target)))
                 kept)
            (append-map (match-lambda
                          ((origin . clause)
                           (clause-options origin clause top)))
                        clauses)
            (if (any (lambda (entry) (equal? (cdr entry) '(guix-daemon))) clauses)
                (guix-daemon-options project)
                '())
            podman-tmp
            (if podman?
                '("--expose=@CONTAINED_PODMAN_SOCKET@=/run/contained-agent/podman")
                '())
            ;; Only this central-policy exception may expose SSH resources.
            ;; Mount the socket itself, never the runtime directory or keys.
            (if ssh-dir
                (list (string-append "--expose=" ssh-dir
                                     "/ssh.sock=/run/contained-agent/ssh.sock")
                      (string-append "--expose=" ssh-dir "/known_hosts="
                                     home "/.ssh/known_hosts")
                      (string-append "--expose=" ssh-dir "/config="
                                     home "/.ssh/config"))
                '())
            (spec-preserve common)
            (spec-preserve spec)
            credentials
            (match (local-file (approved-manifest-name manifest))
              (#f '())
              (manifest (list (string-append "--manifest=" manifest))))
            packages
            (if ssh-dir '("openssh") '())
            (list "--" "bash" "-c" "\
# Guix creates HOME on tmpfs (default mode 1777).  OpenSSH checks its
# permissions when reading ~/.ssh/config.  This is the synthetic home,
# not a bind mount of the host's home; do not chmod its mounted children.
chmod 700 -- \"$1\" || exit; shift
export SSL_CERT_FILE=$GUIX_ENVIRONMENT/etc/ssl/certs/ca-certificates.crt
export GIT_SSL_CAINFO=$SSL_CERT_FILE SSL_CERT_DIR=$GUIX_ENVIRONMENT/etc/ssl/certs
unset SSH_AUTH_SOCK SSH_AGENT_PID
cd \"$1\" || exit; hooks=$2 allow=$3 envrc=$4 n=$5; shift 5
while [ $n -gt 0 ]; do cp \"$1\" \"$2\" || exit; shift 2; n=$((n - 1)); done
# The session's own ~/.gitconfig, which the agent may change, on top of any
# seeded copy.  .git/config is read-only, so `git push -u' cannot record an
# upstream: push the current branch to its namesake without one.  --file,
# as --global would write a read-only ~/.config/git/config if mounted.
c() { git config --file \"$HOME/.gitconfig\" \"$@\" || exit; }
if [ -e \"$HOME/.gitconfig.local\" ]; then c include.path \"$HOME/.gitconfig.local\"; fi
c push.default current
c filter.lfs.clean 'git-lfs clean -- %f'
c filter.lfs.smudge 'git-lfs smudge -- %f'
c filter.lfs.process 'git-lfs filter-process'
c filter.lfs.required true
if [ -n \"$hooks\" ]; then c core.hooksPath \"$hooks\"; fi
# The host's direnv approval of the work tree's .envrc, as direnv records it.
if [ -n \"$allow\" ]; then
  d=${XDG_DATA_HOME:-$HOME/.local/share}/direnv/allow
  mkdir -p -- \"$d\" && printf '%s\\n' \"$envrc\" > \"$d/$allow\" || exit
fi
# Load direnv for the agent itself, then again before each of its commands,
# which may run elsewhere or after .envrc changed.  Claude Code runs
# $CLAUDE_ENV_FILE after its shell snapshot, which resets PATH, so BASH_ENV,
# read by other agents' bash, leaves Claude alone.  BASH_ENV is unset first,
# as direnv evaluates .envrc with bash.  Those commands log errors only:
# direnv 2.37 reads DIRENV_LOG_FORMAT only when it has a configuration file.
if command -v direnv >/dev/null; then
  eval \"$(direnv export bash)\"
  d=${XDG_CONFIG_HOME:-$HOME/.config}/direnv
  mkdir -p -- \"$d\" && : >> \"$d/direnv.toml\" || exit
  d=$HOME/.local/share/contained-agent
  mkdir -p -- \"$d\" || exit
  printf '%s\\n' 'eval \"$(DIRENV_LOG_FORMAT= direnv export bash)\"' \\
    > \"$d/direnv.bash\" || exit
  printf '%s\\n' 'unset BASH_ENV' \\
    '[ -n \"${CLAUDECODE-}\" ] || . \"$HOME/.local/share/contained-agent/direnv.bash\"' \\
    > \"$d/bash-env\" || exit
  export CLAUDE_ENV_FILE=$d/direnv.bash BASH_ENV=$d/bash-env
fi
exec \"$@\""
                  "contained-agent"
                  home
                  (if project workdir home)
                  (or (git-hooks clauses) "")
                  (or direnv "")
                  (if direnv (string-append top "/.envrc") "")
                  (number->string (length seeded)))
            (append-map (match-lambda
                          ((source . target) (list target source)))
                        seeded)
            ;; Overlays need a mount namespace of the agent's own, which
            ;; bubblewrap sets up without privileges.
            (match (append (spec-overlay spec) (spec-overlay common)
                           (append-map (match-lambda
                                         ((file . target)
                                          (list "--bind" target file)))
                                       kept))
              (() '())
              (options
               (append (list "bwrap" "--dev-bind" "/" "/" "--die-with-parent")
                       options
                       (list "--"))))
            (if ssh-dir
                '("env" "SSH_AUTH_SOCK=/run/contained-agent/ssh.sock")
                '())
            (if podman?
                (list "bash" "-c" %podman-remote-setup "podman-remote"
                      (or (assq-ref podman? 'tmpdir) ""))
                '())
            (list (assq-ref spec 'program))
            (or (assq-ref spec 'arguments) '())
            args)))))

(define* (contained-agent-main command-line
                               #:key agents common packages git
                               (ssh-tools '())
                               (podman-launcher #f)
                               (projects-file
                                "~/.config/contained-agent/projects.scm")
                               (github-secrets (%github-secrets))
                               projects-secret)
  "Run the agent named by COMMAND-LINE in a container, or approve a project's
local files with `contained-agent allow [DIRECTORY]', or take those of the
checkout it inherits from with `contained-agent inherit [DIRECTORY]'.
AGENTS maps agent names to specs and COMMON is a spec for every agent (see
the commentary); PACKAGES
are the specifications installed in the container; GIT is the git executable
used to inspect the project.  GITHUB-SECRETS is the directory of the
GitHub token tiers, or #f if this host has none, and PROJECTS-SECRET, if not
#f, is a host-private projects file; SOPS decrypts both."
  (catch 'contained-ssh-error
   (lambda ()
    (parameterize ((%podman-launcher podman-launcher)
                   (%github-secrets github-secrets)
                   (%projects-secret projects-secret))
    (match command-line
    ((program args ...)
     (match (cons (program-name program) args)
       (("contained-agent" "allow") (allow "." git projects-file))
       (("contained-agent" "allow" directory) (allow directory git projects-file))
       (("contained-agent" "inherit")
        (inherit "." git projects-file ssh-tools))
       (("contained-agent" "inherit" directory)
        (inherit directory git projects-file ssh-tools))
       (("contained-agent" "podman-stop" runtime-id)
        (unless podman-launcher
          (die "Podman runtime launcher is not configured"))
        (apply execlp (car podman-launcher)
               (append podman-launcher (list "--stop" runtime-id))))
       (("contained-agent" "podman-check" runtime-id)
        (unless podman-launcher
          (die "Podman runtime launcher is not configured"))
        (apply execlp (car podman-launcher)
               (append podman-launcher (list "--check" runtime-id))))
       (("contained-agent" "podman-service")
        ;; The shared outer engine; Home or system Shepherd normally runs it.
        (unless podman-launcher
          (die "Podman runtime launcher is not configured"))
        (apply execlp (car podman-launcher)
               (append podman-launcher (list "--host-service"))))
       (("contained-agent" "ssh-service")
        (serve-project-ssh git projects-file ssh-tools))
       (("contained-agent" (and action (or "ssh-start" "ssh-stop" "ssh-socket"))
                           directories ...)
        (when (> (length directories) 1)
          (die "usage: contained-agent ~a [DIRECTORY]" action))
        (let* ((directory (canonicalize-path
                           (if (null? directories) (getcwd) (car directories))))
               (info (command-lines git "-C" directory "rev-parse"
                                    "--path-format=absolute" "--show-toplevel"
                                    "--git-common-dir"))
               (project (match info
                          ((top common) (resolve top))
                          (_ directory)))
               (policy (and (string=? action "ssh-start")
                            (ssh-policy (map cdr (central-entries projects-file project git))))))
          (match action
            ("ssh-start" (display (ssh-start project policy ssh-tools)) (newline))
            ("ssh-stop" (ssh-stop project ssh-tools))
            ("ssh-socket"
             (display (string-append (ssh-runtime project ssh-tools) "/ssh.sock"))
             (newline)))))
       (("contained-agent" name args ...)
        (run-agent name args agents common packages git projects-file ssh-tools))
       (("contained-agent")
        (die "usage: contained-agent AGENT [ARGS...] | allow|inherit|ssh-start|ssh-stop|ssh-socket [DIRECTORY] | podman-service | podman-check|podman-stop RUNTIME_ID"))
       ((name args ...)
        (run-agent name args agents common packages git projects-file ssh-tools)))))))
   (lambda (_ message) (die "~a" message))))
