(define-module (uraj bin contained-agent)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 match)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 regex)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:use-module (srfi srfi-26)
  #:use-module (uraj bin contained-ssh)
  #:export (contained-agent-main))

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
;;;   sandbox cannot see, keyed by the repository's main work tree:
;;;
;;;     (project "~/src/uraj"
;;;       (expose "/var/log" "~/.local/state/shepherd")
;;;       (share PATH ...)
;;;       (preserve "HF_TOKEN" "WANDB_.*"))
;;;
;;;   and from the project itself: `.guix/contained-agent.scm' holds the same
;;;   mount/environment clauses at top level.  Only central configuration
;;;   may also declare (ssh-agent (identity PATH (destinations HOST ...)));
;;;   its keys are loaded automatically on the host before entering.
;;;   The local file lives next to `.guix/manifest.scm' (or a top-level
;;;   `manifest.scm'), whose packages join the container's.  Both are written
;;;   by the agent, and the manifest is Scheme that `guix shell' evaluates on
;;;   the host, so they count only once `contained-agent allow' has shown them
;;;   to the user and copied them away; sessions load that copy, chosen by the
;;;   hash of the project's current files.  Changed or unreviewed files are
;;;   left out with a warning.
;;; - Files under %denied are never mounted on request.
;;;
;;; Projects files are `read', never evaluated.
;;;
;;; Agents and the mounts common to all of them are data from the caller, an
;;; alist per agent with the keys below (all but `program' optional):
;;;
;;;   program   the real executable
;;;   state     directories created if missing and shared read-write
;;;   share     paths shared read-write when they exist
;;;   expose    paths exposed read-only when they exist
;;;   protect   files within `state' read by agents outside the sandbox as
;;;             configuration (hooks, MCP commands, instructions): created
;;;             if missing, empty (a directory if the name ends in /), and
;;;             exposed read-only along with what they link to.  A name
;;;             ending in * stands for the existing files it prefixes.
;;;             Mounts follow links, so a link itself cannot be pinned: use
;;;             `overlay' for directories holding some.
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
     (values (if (string-suffix? "/.git" common) (dirname common) top)
             top
             (git-mounts git top common gitdir)))
    (_
     (values workdir workdir (share workdir)))))

;;; Requested mounts.

(define %denied
  ;; Credentials, Paseo's keys (control of every session), our own
  ;; configuration and approvals, the build daemon (use the explicit
  ;; guix-daemon clause instead), and the user's service managers.
  '("~/.paseo" "~/.paseo-password" "~/.ssh" "~/.gnupg" "~/.password-store"
    "~/.config/contained-agent" "~/.local/state/contained-agent"
    "~/.cache/contained-agent"
    "/var/guix/daemon-socket" "/run/user"))

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

(define (clause-options origin clause)
  (match clause
    ;; Applied after ordinary mappings so cache/GC-root mounts take priority.
    (('guix-daemon) '())
    (('expose files ...) (append-map (requested expose origin) files))
    (('share files ...) (append-map (requested share origin) files))
    ;; Host environment variables, by name regexp, passed when set.
    (('preserve (? string? names) ...)
     (map (cut string-append "--preserve=^" <> "$") names))
    (_ (die "~a: bad clause ~s" origin clause))))

(define (read-all file)
  (call-with-input-file file
    (lambda (port)
      (let loop ((acc '()))
        (match (read port)
          ((? eof-object?) (reverse acc))
          (form (loop (cons form acc))))))))

(define (central-clauses file project)
  (if (file-exists? file)
      (append-map
       (match-lambda
         (('project (? string? root) clauses ...)
          (if (string=? (resolve (expand-home root)) (resolve project)) clauses '()))
         (form (die "~a: bad entry ~s" file form)))
       (read-all file))
      '()))

(define (central-entries file project)
  "Append managed and host-private central clauses, preserving their origins.
The private file is read at runtime, never imported into the Guix store."
  (append-map
   (lambda (source)
     (map (cut cons source <>) (central-clauses source project)))
   (delete-duplicates
    (list (expand-home (or (getenv "CONTAINED_AGENT_PROJECTS") file))
          (expand-home "~/.config/contained-agent/projects.local.scm")))))

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
  (string-map (lambda (c) (if (char=? c #\/) #\% c)) project))

(define (local-files top)
  "Return the name of work tree TOP's project-local files, `.guix' or
`manifest.scm', or #f."
  (find (lambda (name)
          (file-exists? (string-append top "/" name)))
        '(".guix" "manifest.scm")))

(define (nar-hash file)
  (match (command-lines "guix" "hash" "--serializer=nar" file)
    ((hash) hash)
    (_ (die "cannot hash ~a" file))))

(define (copy-local source target)
  "Copy SOURCE, `.guix' or `manifest.scm', to TARGET, a directory then holding
manifest.scm and/or contained-agent.scm.  Links could reach files nobody
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

(define (approved-local top)
  "Return the approved copy of work tree TOP's project-local files, or #f."
  (match (local-files top)
    (#f #f)
    (name
     (let* ((source (string-append top "/" name))
            (copy (state-directory "approved" (nar-hash source))))
       (if (file-exists? copy)
           copy
           (begin
             (warn "~a is new or changed since `contained-agent allow ~a'; \
starting without it" source top)
             #f))))))

(define (allow directory)
  "Show the project-local files of DIRECTORY's work tree against the last
approved ones and, once the user agrees, approve them."
  (let*-values (((project top _)
                 (project-mounts "git" (canonicalize-path directory)))
                ((name) (or (local-files top)
                            (die "~a has neither .guix nor manifest.scm" top)))
                ((source) (string-append top "/" name))
                ((latest) (state-directory "projects" (project-key project)))
                ((staging) (state-directory
                            (string-append "staging-"
                                           (number->string (getpid))))))
    (mkdir-p (state-directory "approved"))
    (mkdir-p (state-directory "projects"))
    ;; Review and keep a copy: the work tree may change meanwhile.  Its hash
    ;; equals that of SOURCE as long as they are identical.
    (if (directory? source)
        (copy-local source staging)
        (begin
          (mkdir staging)
          (copy-file source (string-append staging "/" name))))
    (let* ((hash (nar-hash (string-append staging
                                          (if (directory? source)
                                              ""
                                              (string-append "/" name)))))
           (target (state-directory "approved" hash)))
      (unless (directory? source)
        (rename-file (string-append staging "/" name)
                     (string-append staging "/manifest.scm")))
      (unless (file-exists? latest)
        (mkdir-p (state-directory "empty")))
      (system* "git" "--no-pager" "diff" "--no-index" "--"
               (if (file-exists? latest) latest (state-directory "empty"))
               staging)
      (unless (isatty? (current-input-port))
        (system* "rm" "-rf" staging)
        (die "approving needs a terminal"))
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

;;; Agents.

(define (protected file)
  "Return the files that FILE, an entry of a spec's `protect', stands for,
creating it if need be."
  (cond ((string-suffix? "*" file)
         (let ((dir (dirname file))
               (prefix (basename (string-drop-right file 1))))
           (map (cut string-append dir "/" <>)
                (or (scandir dir (cut string-prefix? prefix <>)) '()))))
        ((string-suffix? "/" file)
         (mkdir-p file)
         (list (string-drop-right file 1)))
        (else
         (unless (file-exists? file)
           (close-port (open-output-file file)))
         (list file))))

(define (spec-ref spec key)
  (map expand-home (or (assq-ref spec key) '())))

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
  (let* ((protected (append-map protected (spec-ref spec 'protect))))
    (append
     (append-map (lambda (dir)
                   (mkdir-p dir)
                   (share dir))
                 (spec-ref spec 'state))
     (append-map (lambda (file)
                   (if (file-exists? file) (share file) '()))
                 (spec-ref spec 'share))
     (append-map expose (spec-ref spec 'expose))
     ;; A link's target may be shared under another name.
     (append-map expose (delete-duplicates
                         (append protected (map resolve protected))))
     ;; Overlays are mounted within the container, over what is exposed.
     (append-map expose (spec-ref spec 'overlay)))))

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
                                      (expand-home projects-file) project)))))
              (when policy (ssh-ensure project policy ssh-tools))
              (reply "ok" "")))
          (lambda (_ message) (reply "error" message)))
        (loop)))))

(define (run-agent name args agents common packages git projects-file ssh-tools)
  (let*-values
      (((spec) (or (assoc-ref agents name)
                   (die "unknown agent ~a" name)))
       ((home) (getenv "HOME"))
       ((workdir) (working-directory))
       ((project top mounts)
        ;; Paseo's helper app-servers (model lists etc.) and stray launches
        ;; from $HOME get an empty home instead of the whole of it.
        (if (member workdir (list home "/"))
            (values #f #f '())
            (project-mounts git workdir)))
       ((projects-file) (expand-home (or (getenv "CONTAINED_AGENT_PROJECTS")
                                         projects-file)))
       ((local) (and top (approved-local top)))
       ((local-file) (lambda (name)
                       (let ((file (and local (string-append local "/" name))))
                         (and file (file-exists? file) file))))
       ((central) (if project (central-entries projects-file project) '()))
       ((ssh) (ssh-policy (map cdr central)))
       ;; Version probes must not depend on SSH provisioning.
       ((ssh-dir) (and ssh (not (member args '(("--version") ("auth" "status"))))
                       (if (getenv "CONTAINED_AGENT_SSH_PREPARED")
                           (ssh-prepared-directory project ssh ssh-tools)
                           (ssh-ensure project ssh ssh-tools))))
       ((clauses)
        ;; (ORIGIN . CLAUSE), ORIGIN naming the file for messages.
        (append
         (remove (match-lambda
                   ((origin . clause)
                    (and (pair? clause) (eq? (car clause) 'ssh-agent))))
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
    (apply execlp "guix" "guix" "shell"
           "--container" "--no-cwd" "--network" "--expose=/gnu/store"
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
                          ((origin . clause) (clause-options origin clause)))
                        clauses)
            (if (any (lambda (entry) (equal? (cdr entry) '(guix-daemon))) clauses)
                (guix-daemon-options project)
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
            (match (local-file "manifest.scm")
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
cd \"$1\" || exit; n=$2; shift 2
while [ $n -gt 0 ]; do cp \"$1\" \"$2\" || exit; shift 2; n=$((n - 1)); done
exec \"$@\""
                  "contained-agent"
                  home
                  (if project workdir home)
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
            (list (assq-ref spec 'program))
            args))))

(define* (contained-agent-main command-line
                               #:key agents common packages git
                               (ssh-tools '())
                               (projects-file
                                "~/.config/contained-agent/projects.scm"))
  "Run the agent named by COMMAND-LINE in a container, or approve a project's
local files with `contained-agent allow [DIRECTORY]'.  AGENTS maps agent names
to specs and COMMON is a spec for every agent (see the commentary); PACKAGES
are the specifications installed in the container; GIT is the git executable
used to inspect the project."
  (catch 'contained-ssh-error
   (lambda ()
    (match command-line
    ((program args ...)
     (match (cons (program-name program) args)
       (("contained-agent" "allow") (allow "."))
       (("contained-agent" "allow" directory) (allow directory))
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
                          ((top common)
                           (resolve (if (string-suffix? "/.git" common)
                                        (dirname common) top)))
                          (_ directory)))
               (policy (and (string=? action "ssh-start")
                            (ssh-policy (map cdr (central-entries projects-file project))))))
          (match action
            ("ssh-start" (display (ssh-start project policy ssh-tools)) (newline))
            ("ssh-stop" (ssh-stop project ssh-tools))
            ("ssh-socket"
             (display (string-append (ssh-runtime project ssh-tools) "/ssh.sock"))
             (newline)))))
       (("contained-agent" name args ...)
        (run-agent name args agents common packages git projects-file ssh-tools))
       (("contained-agent")
        (die "usage: contained-agent AGENT [ARGS...] | allow|ssh-start|ssh-stop|ssh-socket [DIRECTORY]"))
       ((name args ...)
        (run-agent name args agents common packages git projects-file ssh-tools))))))
   (lambda (_ message) (die "~a" message))))
