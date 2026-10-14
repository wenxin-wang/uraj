;;; Runtime provisioning.  Never flush unrelated tables or delete networks.
(define-module (uraj build restricted-network)
  #:use-module (guix build utils)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module (uraj network-policy)
  #:use-module (uraj build restricted-network-docker)
  #:export (conflicting-routes check-topology-transition
            ensure-restricted-networks))

(define (conflicting-routes routes topology)
  (filter
   (lambda (route)
     (let ((dst (assoc-ref route "dst")))
       (and dst (not (member dst '("default" "0.0.0.0/0")))
            (not (equal? (assoc-ref route "dev") (list-ref topology 2)))
            (ipv4-overlap? (list-ref topology 3) dst))))
   (vector->list routes)))

(define (check-topology-transition previous table topologies)
  (match previous
    ((old-table old-topologies)
     (unless (and (equal? old-table table)
                  (every (lambda (old) (member old topologies)) old-topologies))
       (error "Network removal/renumbering/table rename requires offline cleanup"
              previous (list table topologies))))
    (_ (error "Invalid restricted-network state" previous))))

(define* (ensure-restricted-networks docker nft ip rules table topologies egress
                                    #:key (state-directory "/var/lib/restricted-network"))
  (setenv "DOCKER_HOST" "unix:///var/run/docker.sock")
  (unsetenv "DOCKER_CONTEXT")
  (umask #o077)
  (mkdir-p state-directory)
  ;; Serializes reloads including manual starts of the generated program.
  (let ((lock (open-file (string-append state-directory "/lock") "a"))
        (state (string-append state-directory "/topology.scm")))
    (dynamic-wind
      (lambda () (flock lock LOCK_EX))
      (lambda ()
        (when (file-exists? state)
          (check-topology-transition (call-with-input-file state read)
                                     table topologies))
        (let ((routes (read-command-json ip "-j" "-4" "route" "show" "table" "all"))
              (bridges (map (lambda (t) (list-ref t 2)) topologies)))
          (for-each
           (lambda (interface)
             (unless (or (member interface bridges)
                         (file-exists? (string-append "/sys/class/net/" interface)))
               (error "Missing egress interface" interface))) egress)
          (for-each
           (lambda (topology)
             (let ((conflicts (conflicting-routes routes topology)))
               (unless (null? conflicts)
                 (error "Restricted subnet overlaps host/VPN routes" conflicts)))
             (check-docker-network docker topology)) topologies))
        (invoke nft "--check" "--file" rules)
        ;; Reserve topology BEFORE applying rules/creating interfaces.  A crash
        ;; or failed create can leave a reservation, never an untracked bridge.
        (call-with-output-file (string-append state ".new")
          (lambda (port) (write (list table topologies) port) (newline port)))
        (rename-file (string-append state ".new") state)
        (invoke nft "--file" rules)
        (for-each (lambda (topology) (ensure-docker-network docker topology))
                  topologies))
      (lambda () (close-port lock)))))
