;;; Runtime provisioning.  Never flush unrelated tables or delete networks.
(define-module (uraj build restricted-network)
  #:use-module (guix build utils)
  #:use-module (ice-9 match)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:use-module (uraj network-policy)
  #:use-module (uraj build restricted-network-docker)
  #:export (conflicting-routes check-topology-transition read-host-dns
            wait-for-host-dns bypass-rule-subnet
            ensure-restricted-networks))

(define (dns-ipv4-upstream address)
  (if (string-index address #\:)
      (begin
        ;; Dual-stack resolv.conf may include an IPv6 scope such as %host0.
        ;; Validate the address, but do not grant IPv6 in an IPv4-only network.
        (match (string-split address #\%)
          ((ip) (inet-pton AF_INET6 ip))
          ((ip scope)
           (when (string-null? scope)
             (error "Empty IPv6 DNS scope" address))
           (inet-pton AF_INET6 ip))
          (_ (error "Malformed IPv6 DNS address" address)))
        #f)
      (begin
        (inet-pton AF_INET address)
        (when (any (lambda (range) (ipv4-overlap? address range))
                   '("0.0.0.0/8" "127.0.0.0/8" "169.254.0.0/16"
                     "224.0.0.0/4" "240.0.0.0/4"))
          (error "Host DNS must be a reachable IPv4 upstream" address))
        address)))

(define (read-host-dns file)
  ;; Read once: both firewall grants and the workload snapshot use this list.
  (let ((servers
         (delete-duplicates
          (filter-map
           (lambda (line)
             (let* ((comment (string-index line (lambda (c) (memv c '(#\# #\;)))))
                    (words (string-tokenize
                            (if comment (substring line 0 comment) line))))
               (match words
                 (("nameserver" address)
                  (dns-ipv4-upstream address))
                 (("nameserver" . _) (error "Malformed nameserver line" line))
                 (_ #f))))
           (string-split (call-with-input-file file get-string-all) #\newline)))))
    (when (null? servers) (error "No IPv4 nameservers in host resolver file" file))
    servers))

(define* (wait-for-host-dns ip egress file #:key (attempts 30) (pause sleep))
  ;; Guix's networking provision only means dhcpcd has been spawned.  Wait
  ;; for a default IPv4 route on an uplink and usable resolver contents.
  ;; EGRESS may be #t to accept any routed interface.
  (let loop ((remaining attempts))
    (let* ((failure #f)
           (servers
            (catch #t
              (lambda ()
                (unless (any (lambda (route)
                               (and (assoc-ref route "dev")
                                    (or (eq? egress #t)
                                        (member (assoc-ref route "dev") egress))))
                             (vector->list
                              (read-command-json ip "-j" "-4" "route" "show" "default")))
                  (error "No default IPv4 route on an allowed egress interface" egress))
                (read-host-dns file))
              (lambda (key . args)
                (set! failure (cons key args))
                #f))))
      (cond (servers servers)
            ((<= remaining 1)
             (error "Timed out waiting for IPv4 uplink and upstream DNS"
                    egress file "Last failure:" failure))
            (else (pause 1) (loop (- remaining 1)))))))

(define (conflicting-routes routes topology)
  (filter
   (lambda (route)
     (let ((dst (assoc-ref route "dst")))
       (and dst (not (member dst '("default" "0.0.0.0/0")))
            (not (equal? (assoc-ref route "dev") (list-ref topology 2)))
            (ipv4-overlap? (list-ref topology 3) dst))))
   (vector->list routes)))

;; A full-tunnel VPN such as strongSwan ("from all lookup 220", pref 220)
;; puts a default route in its own table, which captures bridge subnets in
;; both directions.  That table never names the subnets, so conflicting-routes
;; cannot see it; an opt-in rule ahead of it keeps them in the main table.
(define (bypass-rule-subnet rule)
  ;; Subnet of an unconditional "to SUBNET lookup main" rule, otherwise #f.
  (let ((dst (assoc-ref rule "dst")) (len (assoc-ref rule "dstlen")))
    (and dst len
         (equal? (assoc-ref rule "table") "main")
         (member (assoc-ref rule "src") (list #f "all"))
         (not (assoc-ref rule "iif")) (not (assoc-ref rule "oif"))
         (not (assoc-ref rule "fwmark"))
         (string-append dst "/" (number->string len)))))

(define (ensure-bypass-rules ip priority topologies)
  (let* ((priority (number->string priority))
         (subnets (map (lambda (t) (list-ref t 3)) topologies))
         (rules (vector->list
                 (read-command-json ip "-j" "-4" "rule" "show"
                                    "pref" priority)))
         (existing (map bypass-rule-subnet rules)))
    (unless (every (lambda (subnet) (and subnet (member subnet subnets)))
                   existing)
      (error "Routing rule priority already in use" priority rules))
    (for-each (lambda (subnet)
                (unless (member subnet existing)
                  (invoke ip "-4" "rule" "add" "pref" priority
                          "to" subnet "lookup" "main")))
              subnets)))

(define (check-bridge-routes ip topologies)
  ;; Also without a bypass: fail loudly rather than run a capture-routed net.
  (for-each
   (lambda (topology)
     (let* ((probe (car (string-split (list-ref topology 3) #\/)))
            (route (vector-ref (read-command-json ip "-j" "-4" "route" "get" probe)
                               0)))
       (unless (equal? (assoc-ref route "dev") (list-ref topology 2))
         (error "Restricted subnet does not route through its bridge"
                topology route))))
   topologies))

(define (check-topology-transition previous table topologies)
  (match previous
    ((old-table old-topologies)
     (unless (and (equal? old-table table)
                  (every (lambda (old) (member old topologies)) old-topologies))
       (error "Network removal/renumbering/table rename requires offline cleanup"
              previous (list table topologies))))
    (_ (error "Invalid restricted-network state" previous))))

(define* (ensure-restricted-networks docker nft ip rules table topologies egress
                                    #:key (state-directory "/var/lib/restricted-network")
                                    (any-egress? #f)
                                    (vpn-bypass-priority #f)
                                    (inherit-host-dns? #f)
                                    (resolv-conf "/etc/resolv.conf")
                                    (dns-attempts 30)
                                    (interface-directory "/sys/class/net")
                                    (runtime-directory "/run/restricted-network"))
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
                         (file-exists? (string-append interface-directory "/" interface)))
               (error "Missing egress interface" interface))) egress)
          (for-each
           (lambda (topology)
             (let ((conflicts (conflicting-routes routes topology)))
               (unless (null? conflicts)
                 (error "Restricted subnet overlaps host/VPN routes" conflicts)))
             (check-docker-network docker topology)) topologies))
        (let* ((servers (and inherit-host-dns?
                             (wait-for-host-dns ip (if any-egress? #t egress) resolv-conf
                                                #:attempts dns-attempts)))
               (effective-rules (if servers
                                    (string-append state-directory "/rules.nft.new")
                                    rules)))
          (when servers
            (call-with-output-file effective-rules
              (lambda (port)
                (display (call-with-input-file rules get-string-all) port)
                (format port "\nadd element inet ~a host_dns { ~a }\n"
                        table (string-join servers ", "))))
            (mkdir-p runtime-directory)
            (call-with-output-file (string-append runtime-directory "/resolv.conf.new")
              (lambda (port)
                (for-each (lambda (address)
                            (format port "nameserver ~a\n" address)) servers)))
            (chmod (string-append runtime-directory "/resolv.conf.new") #o644))
          (invoke nft "--check" "--file" effective-rules)
          ;; Reserve topology BEFORE applying rules/creating interfaces.  A crash
          ;; or failed create can leave a reservation, never an untracked bridge.
          (call-with-output-file (string-append state ".new")
            (lambda (port) (write (list table topologies) port) (newline port)))
          (rename-file (string-append state ".new") state)
          (invoke nft "--file" effective-rules)
          (for-each (lambda (topology) (ensure-docker-network docker topology))
                    topologies)
          (when vpn-bypass-priority
            (ensure-bypass-rules ip vpn-bypass-priority topologies))
          (check-bridge-routes ip topologies)
          (when servers
            (rename-file (string-append runtime-directory "/resolv.conf.new")
                         (string-append runtime-directory "/resolv.conf")))))
      (lambda () (close-port lock)))))
