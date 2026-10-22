;;; Android checks; networking is owned by restricted-network.
(define-module (uraj build redroid)
  #:use-module (guix build utils)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:export (prepare-redroid ensure-redroid-image
            prepare-redroid-container))

(define (prepare-redroid data render-node)
  (unless (string-contains (call-with-input-file "/proc/filesystems" get-string-all)
                           "binder")
    (error "Running kernel lacks binderfs; enable/load Binder before starting redroid"))
  ;; vold aborts without it, and Android reboots in a loop.
  (unless (file-exists? "/sys/fs/fuse/connections")
    (error "FUSE is not loaded; load the fuse module before starting redroid"))
  (unless (and (file-exists? render-node)
               (eq? 'char-special (stat:type (stat render-node))))
    (error "Intel render device is missing" render-node))
  ;; Protect the parent, not Android's data directory: Android owns its
  ;; contents and permissions, including across container recreation.
  (umask #o077)
  (mkdir-p (dirname data))
  (mkdir-p data))

(define (image-field docker tag format)
  ;; FORMAT of TAG's image, or #f if TAG does not exist.
  (let* ((port (open-pipe* OPEN_READ docker "image" "inspect"
                           "--format" format tag))
         (output (string-trim-right (get-string-all port))))
    (and (zero? (status:exit-val (close-pipe port))) output)))

(define (ensure-redroid-image docker tag context)
  ;; The label records which store context TAG was built from, so a changed
  ;; context rebuilds it even when the tag name is unchanged.  The base image
  ;; is referenced by digest and is pulled if missing.
  (setenv "DOCKER_HOST" "unix:///var/run/docker.sock")
  (let ((label (image-field docker tag "{{index .Config.Labels \"uraj.context\"}}"))
        (old (image-field docker tag "{{.Id}}")))
    (unless (equal? label context)
      (invoke docker "build" "--network" "none"
              "--label" (string-append "uraj.context=" context)
              "--tag" tag context)
      ;; The replaced image is now untagged; the container using it, if any,
      ;; was removed on stop (--rm).  Leave it in place if still referenced.
      (when old
        (system* docker "image" "rm" old)))))

(define (container-exists? docker name)
  (let* ((port (open-pipe* OPEN_READ docker "container" "inspect"
                           "--format" "{{.Id}}" name))
         (output (get-string-all port)))
    (and (zero? (status:exit-val (close-pipe port)))
         (not (string-null? output)))))

(define* (prepare-redroid-container docker name
                                    #:key image context (attempts 60))
  "Run before `docker run' starts NAME: wait for Docker, build the layered
IMAGE from CONTEXT unless IMAGE is #f, and remove a container still named NAME.
dockerd removes a --rm container left by an unclean shutdown only some time
after it restarts, and `run' would fail on the name meanwhile.  Give up after
ATTEMPTS seconds for each wait."
  (setenv "DOCKER_HOST" "unix:///var/run/docker.sock")
  (define (retry what done?)
    (let loop ((remaining attempts))
      (unless (done?)
        (when (zero? remaining)
          (error what name))
        (sleep 1)
        (loop (- remaining 1)))))
  ;; Shepherd starts this once dockerd runs, not once it answers.
  (retry "Docker is not ready for"
         (lambda ()
           (zero? (status:exit-val
                   (system* docker "version" "--format" "{{.Server.Version}}")))))
  (when image
    (ensure-redroid-image docker image context))
  (retry "Cannot remove stale container"
         (lambda ()
           (or (not (container-exists? docker name))
               (begin
                 ;; Removal may already be in progress; then just wait.
                 (system* docker "rm" "--force" name)
                 (not (container-exists? docker name)))))))
