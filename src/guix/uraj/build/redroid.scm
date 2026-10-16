;;; Android checks; networking is owned by restricted-network.
(define-module (uraj build redroid)
  #:use-module (guix build utils)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:export (prepare-redroid ensure-redroid-image))

(define (prepare-redroid data render-node)
  (unless (string-contains (call-with-input-file "/proc/filesystems" get-string-all)
                           "binder")
    (error "Running kernel lacks binderfs; enable/load Binder before starting redroid"))
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
