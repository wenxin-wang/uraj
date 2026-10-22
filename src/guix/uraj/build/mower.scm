(define-module (uraj build mower)
  #:use-module (guix build utils)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:export (ensure-mower-image prepare-mower))

(define (ensure-mower-image docker tag context)
  (setenv "DOCKER_HOST" "unix:///var/run/docker.sock")
  (let* ((port (open-pipe* OPEN_READ docker "image" "inspect" "--format"
                         "{{index .Config.Labels \"uraj.context\"}}" tag))
         (label (string-trim-right (get-string-all port)))
         (status (close-pipe port)))
    (unless (and (zero? status) (string=? label context))
      ;; hypie disables Docker's default bridge. Only build steps use host
      ;; networking for apt/npm/pip; the running service uses redroid's bridge.
      (invoke docker "build" "--network" "host" "--platform" "linux/amd64"
              "--label" (string-append "uraj.context=" context)
              "--tag" tag context))))

(define (prepare-mower data lock)
  (umask #o077)
  (mkdir-p data)
  (chmod data #o700)
  ;; Do not replace an existing inode: maa-cli may already hold its lock.
  (let ((user (getpwnam "maa")))
    (mkdir-p (dirname lock))
    (let ((fd (open-fdes lock (logior O_WRONLY O_CREAT) #o600)))
      (close-fdes fd))
    (chown lock (passwd:uid user) (passwd:gid user))))
