(define-module (uraj bin contained-ssh)
  #:use-module (ice-9 match)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 regex)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:export (ssh-policy ssh-runtime ssh-start ssh-stop ssh-ensure
            ssh-prepared-directory))

;; Host-side SSH lifecycle.  This module never reads a private key itself,
;; evaluates ssh-agent's shell output, or accepts policy from a work tree.
(define (fail fmt . args)
  (throw 'contained-ssh-error (apply format #f fmt args)))

(define (expand path)
  (let ((path (if (string-prefix? "~/" path)
                  (string-append (getenv "HOME") (substring path 1)) path)))
    (unless (string-prefix? "/" path)
      (fail "SSH paths must be absolute or start with ~/: ~a" path))
    path))

(define (capture program . args)
  (let* ((port (apply open-pipe* OPEN_READ program args))
         (text (read-string port))
         (status (close-pipe port)))
    (unless (zero? status) (fail "~a failed" program))
    (string-trim-right text)))

(define (tool tools name)
  (or (assq-ref tools name) (symbol->string name)))

(define (digest tools text)
  ;; TEXT is an argument, never shell source.
  (substring (capture (tool tools 'bash) "-c"
                      "printf '%s' \"$1\" | \"$2\"" "project-hash"
                      text (tool tools 'sha256sum)) 0 64))

(define (ssh-policy clauses)
  "Parse the single central (ssh-agent ...) clause, or return #f."
  (let ((entries (filter (lambda (x) (and (pair? x) (eq? (car x) 'ssh-agent)))
                         clauses)))
    (match entries
      (() #f)
      ((('ssh-agent options ...))
       (let ((known (filter (lambda (x) (and (pair? x)
                                             (eq? (car x) 'known-hosts))) options))
             (configs (filter (lambda (x) (and (pair? x)
                                               (eq? (car x) 'client-config))) options)))
         (when (> (length known) 1) (fail "duplicate SSH known-hosts"))
         (when (> (length configs) 1) (fail "duplicate SSH client-config"))
         (list
          (cons 'known-hosts
          (match known
            (() (expand "~/.ssh/known_hosts"))
            ((('known-hosts (? string? path))) (expand path))
            (_ (fail "expected (known-hosts PATH)"))))
          (cons 'client-config
                (match configs
                  (() "")
                  ((('client-config (? string? text))) text)
                  (_ (fail "expected (client-config STRING)"))))
          (cons 'identities
          (filter-map
           (lambda (entry)
             (match entry
               (('known-hosts _) #f)
               (('client-config _) #f)
               (('identity (? string? path)
                           ('destinations (? string? first) (? string? rest) ...))
                (let ((destinations (cons first rest)))
                  (when (any string-null? destinations)
                    (fail "SSH destinations cannot be empty"))
                  (cons (expand path) destinations)))
               (_ (fail "expected (identity PATH (destinations HOST ...)): ~s"
                        entry))))
           options)))))
      (_ (fail "only one ssh-agent clause is allowed per project")))))

(define (private-directory path create?)
  (when create?
    (catch 'system-error
      (lambda () (mkdir path #o700))
      (lambda args
        (unless (= EEXIST (system-error-errno args)) (apply throw args)))))
  (let ((st (lstat path)))
    (unless (and (eq? (stat:type st) 'directory)
                 (= (stat:uid st) (getuid))
                 (zero? (logand (stat:perms st) #o077)))
      (fail "SSH runtime directory must be owned by you, private, and not a link: ~a"
            path)))
  path)

(define (ssh-runtime project tools)
  (let* ((runtime (or (getenv "XDG_RUNTIME_DIR")
                      (string-append "/run/user/" (number->string (getuid)))))
         ;; A broker's shared SSH service has its own state tree and PID view.
         ;; Never mix its PID records with direct host invocations.
         (base (or (getenv "CONTAINED_AGENT_SSH_RUNTIME_DIRECTORY")
                   (string-append (private-directory runtime #f) "/contained-agent")))
         ;; A 32-hex SHA-256 prefix keeps the complete socket path short.
         (dir (string-append (private-directory base #t) "/"
                             (substring (digest tools (canonicalize-path project))
                                        0 32))))
    (private-directory dir #t)
    (when (> (bytevector-length (string->utf8 (string-append dir "/ssh.sock"))) 107)
      (fail "XDG_RUNTIME_DIR is too long for an SSH socket"))
    dir))

(define (ssh-prepared-directory project policy tools)
  "Check the shared service's prepared files without interpreting its PIDs."
  (let ((dir (ssh-runtime project tools)))
    (with-lock
     dir
     (lambda ()
       (unless (match (read-state dir)
                 ((_ previous)
                  (and (equal? previous (fingerprint project policy tools))
                       (file-exists? (string-append dir "/ssh.sock"))
                       (file-exists? (string-append dir "/known_hosts"))
                       (file-exists? (string-append dir "/config"))))
                 (_ #f))
         (fail "shared SSH preparation is missing or policy changed; retry"))))
    dir))

(define (with-lock dir thunk)
  (let ((port (open-file (string-append dir "/lock") "a")))
    (dynamic-wind
      (lambda () (flock port LOCK_EX))
      thunk
      (lambda () (flock port LOCK_UN) (close-port port)))))

(define (with-socket dir thunk)
  (let ((old (getenv "SSH_AUTH_SOCK")))
    (dynamic-wind
      (lambda () (setenv "SSH_AUTH_SOCK" (string-append dir "/ssh.sock")))
      thunk
      (lambda () (if old (setenv "SSH_AUTH_SOCK" old) (unsetenv "SSH_AUTH_SOCK"))))))

(define* (fingerprint project policy tools
                      #:optional (known-hosts (assq-ref policy 'known-hosts)))
  (digest tools
          (format #f "~s" (list (canonicalize-path project) policy
                                 ;; The filename in sha256sum's output differs
                                 ;; between the host source and its snapshot.
                                 (substring (capture (tool tools 'sha256sum)
                                                     "--" known-hosts) 0 64)))))

(define (read-state dir)
  (let ((path (string-append dir "/state")))
    (and (file-exists? path) (call-with-input-file path read))))

(define (agent-process? pid dir tools)
  ;; Do not signal a reused PID after a crash or reboot.
  ;; ssh-agent is non-dumpable, so even its owner cannot read /proc/PID/exe.
  (and (integer? pid) (> pid 1)
       (false-if-exception
        (and (= (stat:uid (stat (format #f "/proc/~a" pid))) (getuid))
             (match (string-split
                     (call-with-input-file (format #f "/proc/~a/cmdline" pid)
                       read-string) #\nul)
               ((program "-s" "-a" socket "")
                ;; Accept a previous Home generation's ssh-agent too.
                (and (string=? (basename program) "ssh-agent")
                     (string=? socket (string-append dir "/ssh.sock"))))
               (_ #f))))))

(define (stop-unlocked dir tools)
  (match (read-state dir)
    ((pid _)
     (when (agent-process? pid dir tools)
       (kill pid SIGTERM)
       (let loop ((remaining 100))
         (when (agent-process? pid dir tools)
           (when (zero? remaining) (fail "SSH agent did not stop"))
           (usleep 10000)
           (loop (- remaining 1))))))
    (_ #f))
  (for-each (lambda (name)
              (let ((p (string-append dir "/" name)))
                (when (file-exists? p) (delete-file p))))
            '("state" "ssh.sock" "known_hosts" "config")))

(define (ssh-stop project tools)
  (let ((dir (ssh-runtime project tools)))
    (with-lock dir (lambda () (stop-unlocked dir tools)))))

(define (start-unlocked project policy tools dir hash automatic?)
  "Clear and reload identities, preserving a live agent and its socket."
  (let* ((existing (match (read-state dir)
                     ((pid _)
                      (and (agent-process? pid dir tools)
                           (file-exists? (string-append dir "/ssh.sock")) pid))
                     (_ #f)))
         (pid (or existing
                  (begin
                    (stop-unlocked dir tools)
                    (let* ((output (capture (tool tools 'ssh-agent) "-s" "-a"
                                            (string-append dir "/ssh.sock")))
                           (match (string-match "SSH_AGENT_PID=([0-9]+);" output)))
                      (or (and match (string->number (match:substring match 1)))
                          (fail "cannot parse ssh-agent PID")))))))
    ;; Record before loading, so any failure can stop this process.
    (call-with-output-file (string-append dir "/state")
      (lambda (port) (write (list pid #f) port)))
    (catch #t
      (lambda ()
        (with-socket
         dir
         (lambda ()
           (unless (zero? (system* (tool tools 'bash) "-c"
                                   "exec \"$@\" </dev/null >&2" "contained-agent-ssh"
                                   (tool tools 'ssh-add) "-D"))
             (fail "cannot clear SSH identities; project agent stopped"))))
        ;; Keep these inodes too: existing containers bind the individual files.
        (let ((text (call-with-input-file (assq-ref policy 'known-hosts) read-string)))
          (call-with-output-file (string-append dir "/known_hosts")
            (lambda (port) (display text port))))
        ;; Literal client config is interpreted only by SSH in the container.
        ;; Never run ssh -G on this host-side text: Match exec could run code.
        (let ((path (string-append dir "/config")))
          (call-with-output-file path
            (lambda (port) (display (assq-ref policy 'client-config) port)))
          (chmod path #o600))
        (unless (equal? hash (fingerprint project policy tools
                                         (string-append dir "/known_hosts")))
          (fail "known_hosts changed while preparing SSH agent; retry"))
        (with-socket
         dir
         (lambda ()
           (for-each
            (lambda (identity)
              (unless (zero? (apply system*
                                    (append
                                     ;; Never consume Paseo's protocol input
                                     ;; or write setup output to its stdout.
                                     ;; ssh-add can still use /dev/tty or
                                     ;; SSH_ASKPASS to unlock encrypted keys.
                                     (if automatic?
                                         (list (tool tools 'bash) "-c"
                                               "exec \"$@\" </dev/null >&2"
                                               "contained-agent-ssh")
                                         '())
                                     (list (tool tools 'ssh-add))
                                     (list "-H" (string-append dir "/known_hosts"))
                                     (append-map (lambda (host) (list "-h" host))
                                                 (cdr identity))
                                     (list "--" (car identity)))))
                ;; ssh-add's stderr above is the actual diagnosis.  A
                ;; missing host key is not a private-key unlock failure.
                (fail "ssh-add failed; project agent stopped.~%  Identity: ~s~%  Destinations: ~s~%  Known hosts: ~s (loaded from a snapshot)~%See ssh-add's original error above. For a non-default port, use the known_hosts spelling [host]:port in destinations.~%After correcting the cause, retry the session or run contained-agent ssh-start ~s on the host."
                      (car identity) (cdr identity) (assq-ref policy 'known-hosts) project)))
            (assq-ref policy 'identities))))
        (call-with-output-file (string-append dir "/state")
          (lambda (port) (write (list pid hash) port))))
      (lambda (key . args)
        (stop-unlocked dir tools)
        (apply throw key args)))))

(define (ssh-start project policy tools)
  "Explicit host command: clear all identities and reload the configured keys."
  (unless policy (fail "no central ssh-agent configuration for ~a" project))
  (let ((dir (ssh-runtime project tools)))
    (with-lock
     dir
     (lambda ()
       (start-unlocked project policy tools dir
                       (fingerprint project policy tools) #f)))
    (string-append dir "/ssh.sock")))

(define (ssh-ensure project policy tools)
  "Reuse a matching agent or start it automatically; return its directory."
  (let ((dir (ssh-runtime project tools)))
    ;; Check and start under the same lock: concurrent sessions must not
    ;; replace each other's newly loaded agent.
    (with-lock
     dir
     (lambda ()
       (let* ((hash (fingerprint project policy tools))
              (ready? (match (read-state dir)
                        ((pid previous)
                         (and (equal? hash previous)
                              (agent-process? pid dir tools)
                              (file-exists? (string-append dir "/config"))
                              (file-exists? (string-append dir "/ssh.sock"))))
                        (_ #f))))
         (unless ready?
           (start-unlocked project policy tools dir hash #t)))))
    dir))
