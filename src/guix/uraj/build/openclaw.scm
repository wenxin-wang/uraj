;;; Runtime preparation for the OpenClaw Gateway and its sandbox engine.
(define-module (uraj build openclaw)
  #:use-module (guix build syscalls)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 regex)
  #:use-module (json)
  #:use-module (srfi srfi-1)
  #:export (openclaw-image-for-tag prepare-openclaw))

(define* (openclaw-image-for-tag image tag #:optional (local-repository "localhost/openclaw-gateway"))
  "Select TAG in IMAGE's repository, or retain the declared digest."
  (let* ((base (car (string-split image #\@)))
         (colon (string-rindex base #\:))
         (slash (or (string-rindex base #\/) -1))
         (repository (if (string-prefix? "sha256:" image) local-repository
                         (if (and colon (> colon slash))
                             (substring base 0 colon) base))))
    (if (not tag) image
        (begin
          (unless (and (string? tag)
                       (string-match "^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$" tag))
            (error "Invalid OpenClaw image tag" tag))
          (string-append repository ":" tag)))))

(define (real-directory path)
  ;; Check all ancestors, not only the final directory: preparation runs as
  ;; root against directories whose contents the container can change.
  (unless (string=? path "/") (real-directory (dirname path)))
  (unless (eq? 'directory (stat:type (lstat path)))
    (error "Expected a real directory" path)))

(define* (private-directory path uid gid #:optional (mode #o700))
  (real-directory (dirname path))
  (unless (file-exists? path) (mkdir path #o700))
  (real-directory path)
  (chown path uid gid)
  (chmod path mode))

(define (resolver-addresses path)
  (let ((addresses
         (call-with-input-file path
           (lambda (port)
             (let loop ((result '()))
               (let ((line (read-line port)))
                 (if (eof-object? line) (reverse result)
                     (let ((parts (string-tokenize line)))
                       (unless (and (= 2 (length parts))
                                    (string=? "nameserver" (car parts)))
                         (error "Invalid restricted-network DNS snapshot"))
                       (let* ((address (cadr parts))
                              (ip (inet-pton AF_INET address)))
                         (when (or (< ip #x01000000)
                                   (<= #x7f000000 ip #x7fffffff)
                                   (<= #xa9fe0000 ip #xa9feffff)
                                   (>= ip #xe0000000))
                           (error "Unusable DNS address" address))
                         (loop (cons address result)))))))))))
    (when (null? addresses) (error "Empty restricted-network DNS snapshot"))
    (delete-duplicates addresses)))

(define* (prepare-openclaw data secret-files
                          #:key (runtime "/run/openclaw")
                          (engine-runtime "/run/openclaw-engine")
                          (sandbox-state '())
                          (resolver "/run/restricted-network/resolv.conf")
                          (data-mount "/data") (data-type "btrfs")
                          (uid 2010) (gid 2010) (readers "log-readers")
                          (setfacl "setfacl")
                          (current-mounts (mounts)))
  "Check prerequisites before writing, then stage private files and DNS."
  (unless (and (string-prefix? (string-append data-mount "/") data)
               (not (member ".." (string-split data #\/))))
    (error "OpenClaw data must be below its storage mount" data))
  (unless (any (lambda (m)
                 (and (string=? data-mount (mount-point m))
                      (string=? data-type (mount-type m)))) current-mounts)
    (error "OpenClaw storage mount missing; refusing to create directories"))
  (real-directory data-mount)
  ;; SOPS may expose symlinks. Dereference only these trusted input paths;
  ;; the staged files consumed by SecretRef are private regular files.
  (for-each
   (lambda (entry)
     (let ((info (stat (cdr entry))))
       (unless (and (eq? 'regular (stat:type info))
                    (positive? (stat:size info)))
         (error "Missing or empty OpenClaw secret" (car entry)))))
   secret-files)
  (let ((dns (resolver-addresses resolver))
        ;; READERS may list and read workspaces, e.g. to collect reports.
        (reader-gid (if (integer? readers) readers (group:gid (getgrnam readers)))))
    (umask #o077)
    ;; DATA stays root-owned; do not recursively chmod/chown user state.
    ;; Readers may traverse to workspaces, but not into home or engine.
    (private-directory data 0 reader-gid #o750)
    (private-directory (string-append data "/home") uid gid)
    ;; The engine binds these before OpenClaw would create them.
    (for-each
     (lambda (part)
       (let loop ((parts (string-split part #\/))
                  (path (string-append data "/home")))
         (unless (null? parts)
           (let ((next (string-append path "/" (car parts))))
             (private-directory next uid gid)
             (loop (cdr parts) next)))))
     sandbox-state)
    (private-directory (string-append data "/engine") uid gid)
    (for-each
     (lambda (path)
       ;; Readers get access only through ACLs.  crun creates mount points
       ;; here in a keep-id user namespace, where root's DAC override needs
       ;; both owner and group mapped; the reader group is not
       ;; (podman#27785), so it must not own these directories.
       (private-directory path uid gid #o750)
       (let ((acl (format #f "g:~a:rX,d:g:~a:rX" reader-gid reader-gid)))
         (unless (zero? (system* setfacl "-m" acl path))
           (error "Could not set the workspace reader ACL" path))))
     (list (string-append data "/workspaces")
           (string-append data "/workspaces/main")))
    (private-directory runtime 0 0)
    (private-directory engine-runtime uid gid)
    ;; A socket left by a killed engine would block its restart.
    (let ((socket (string-append engine-runtime "/podman.sock")))
      (when (false-if-exception (lstat socket)) (delete-file socket)))
    (for-each
     (lambda (entry)
       (let* ((target (string-append runtime "/" (car entry)))
              (temporary (string-append target ".new")))
         ;; RUNTIME is root-only, so the container cannot replace these paths.
         (when (file-exists? temporary) (delete-file temporary))
         (copy-file (cdr entry) temporary)
         (chown temporary uid gid)
         (chmod temporary #o400)
         (rename-file temporary target)))
     secret-files)
    (call-with-output-file (string-append runtime "/compose-dns.json.new")
      (lambda (port)
        (let ((entry `((dns . ,(list->vector dns)))))
          (scm->json `((services . ((gateway . ,entry) (engine . ,entry))))
                     port))))
    (rename-file (string-append runtime "/compose-dns.json.new")
                 (string-append runtime "/compose-dns.json"))))
