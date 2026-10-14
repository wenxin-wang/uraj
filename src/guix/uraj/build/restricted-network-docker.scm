;;; Docker is a network attachment backend, not the firewall owner.
(define-module (uraj build restricted-network-docker)
  #:use-module (guix build utils)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 rdelim)
  #:use-module (json)
  #:export (read-command-json docker-network-matches?
            check-docker-network ensure-docker-network))

(define (read-command-json . command)
  (let* ((port (apply open-pipe* OPEN_READ command))
         (value (json->scm port))
         (status (close-pipe port)))
    (unless (zero? status) (error "Command failed" command status))
    value))

;; TOPOLOGY is (name backend bridge subnet gateway), plain data usable by
;; future backends without importing Guix configuration records at runtime.
(define (docker-network-matches? net topology)
  (let ((options (assoc-ref net "Options"))
        (ipam (assoc-ref (assoc-ref net "IPAM") "Config")))
    (and (equal? (assoc-ref net "Name") (list-ref topology 0))
         (equal? (assoc-ref net "Driver") "bridge")
         (eq? (assoc-ref net "Internal") #f)
         (eq? (assoc-ref net "EnableIPv6") #f)
         (equal? (assoc-ref options "com.docker.network.bridge.name")
                 (list-ref topology 2))
         (equal? (assoc-ref options "com.docker.network.bridge.enable_ip_masquerade")
                 "false")
         (vector? ipam) (= (vector-length ipam) 1)
         (equal? (assoc-ref (vector-ref ipam 0) "Subnet") (list-ref topology 3))
         (equal? (assoc-ref (vector-ref ipam 0) "Gateway") (list-ref topology 4)))))

(define (docker-network-names docker)
  ;; A failed inspect is not proof of absence.  Enumerate first, and fail on
  ;; daemon/permission errors instead of turning them into a create attempt.
  (let* ((port (open-pipe* OPEN_READ docker "network" "ls" "--format" "{{.Name}}"))
         (names (let loop ((names '()))
                  (let ((line (read-line port)))
                    (if (eof-object? line) (reverse names)
                        (loop (cons line names))))))
         (status (close-pipe port)))
    (unless (zero? status) (error "Cannot list Docker networks" status))
    names))

(define (check-docker-network docker topology)
  (let* ((name (car topology))
         (exists? (member name (docker-network-names docker))))
    (if exists?
        (let ((net (vector-ref (read-command-json docker "network" "inspect" name) 0)))
          (unless (docker-network-matches? net topology)
            (error "Existing Docker network differs from declaration" name)))
        (when (file-exists? (string-append "/sys/class/net/" (list-ref topology 2)))
          (error "Bridge exists outside the declared Docker network" topology)))
    (and exists? #t)))

(define (ensure-docker-network docker topology)
  (unless (check-docker-network docker topology)
    (invoke docker "network" "create" "--driver" "bridge"
            "--subnet" (list-ref topology 3) "--gateway" (list-ref topology 4)
            "--opt" (string-append "com.docker.network.bridge.name="
                                   (list-ref topology 2))
            "--opt" "com.docker.network.bridge.enable_ip_masquerade=false"
            (car topology)))
  (check-docker-network docker topology))
