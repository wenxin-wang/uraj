;;; Runtime checks shared by the redroid services and their tests.
(define-module (uraj build redroid)
  #:use-module (guix build utils)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:use-module (json)
  #:use-module (srfi srfi-1)
  #:export (ipv4-overlap? conflicting-routes redroid-network-matches?
            ensure-redroid-network prepare-redroid))

(define (ipv4-range cidr)
  (let* ((parts (string-split cidr #\/))
         (ip (inet-pton AF_INET (car parts)))
         (prefix (if (null? (cdr parts)) 32 (string->number (cadr parts)))))
    (unless (and (integer? prefix) (<= 0 prefix 32))
      (error "Invalid IPv4 prefix" cidr))
    (let* ((size (expt 2 (- 32 prefix)))
           (base (* (quotient ip size) size)))
      (cons base (+ base size -1)))))

(define (ipv4-overlap? left right)
  (let ((a (ipv4-range left)) (b (ipv4-range right)))
    (and (<= (car a) (cdr b)) (<= (car b) (cdr a)))))

(define (conflicting-routes routes subnet bridge)
  ;; Include policy-routing tables (VPNs), not just the main table.  Default
  ;; routes provide egress; an existing route on our own bridge is expected.
  (filter (lambda (route)
            (let ((dst (assoc-ref route "dst")))
              (and dst (not (member dst '("default" "0.0.0.0/0")))
                   (not (equal? (assoc-ref route "dev") bridge))
                   (ipv4-overlap? subnet dst))))
          (vector->list routes)))

(define (redroid-network-matches? net name bridge subnet gateway)
  (let ((options (assoc-ref net "Options"))
        (ipam (assoc-ref (assoc-ref net "IPAM") "Config")))
    (and (equal? (assoc-ref net "Name") name)
         (equal? (assoc-ref net "Driver") "bridge")
         (eq? (assoc-ref net "Internal") #f)
         (eq? (assoc-ref net "EnableIPv6") #f)
         (equal? (assoc-ref options "com.docker.network.bridge.name") bridge)
         (equal? (assoc-ref options "com.docker.network.bridge.enable_ip_masquerade") "false")
         (vector? ipam) (= (vector-length ipam) 1)
         (equal? (assoc-ref (vector-ref ipam 0) "Subnet") subnet)
         (equal? (assoc-ref (vector-ref ipam 0) "Gateway") gateway))))

(define (read-command-json . command)
  (let* ((port (apply open-pipe* OPEN_READ command))
         (value (json->scm port))
         (status (close-pipe port)))
    (unless (zero? status) (error "Command failed" command status))
    value))

(define (ensure-redroid-network docker nft ip rules name bridge subnet gateway)
  (setenv "DOCKER_HOST" "unix:///var/run/docker.sock")
  (let ((conflicts (conflicting-routes
                   (read-command-json ip "-j" "-4" "route" "show" "table" "all")
                   subnet bridge)))
    (unless (null? conflicts)
      (error "Redroid subnet overlaps host/VPN routes" conflicts)))
  ;; Check BEFORE touching a pre-existing network.  Never delete a network
  ;; which might contain other running instances.
  (define (check-network)
    (let ((net (vector-ref (read-command-json docker "network" "inspect" name) 0)))
      (unless (redroid-network-matches? net name bridge subnet gateway)
        (error "Existing redroid network differs from configuration" name))))
  (let ((exists? (zero? (system* docker "network" "inspect" name))))
    (when exists? (check-network))
    (when (and (not exists?)
               (file-exists? (string-append "/sys/class/net/" bridge)))
      (error "Bridge already exists outside the configured Docker network" bridge))
    ;; One atomic transaction, scoped to our tables only.  Load protection
    ;; before creating a bridge, and never leave a gap on service restart.
    (invoke nft "--file" rules)
    (unless exists?
      (invoke docker "network" "create" "--driver" "bridge"
              "--subnet" subnet "--gateway" gateway
              "--opt" (string-append "com.docker.network.bridge.name=" bridge)
              "--opt" "com.docker.network.bridge.enable_ip_masquerade=false"
              name))
    (check-network)))

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
