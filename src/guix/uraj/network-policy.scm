;;; Declarative policy and nftables generation, independent of Docker.
(define-module (uraj network-policy)
  #:use-module (guix records)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)
  #:export (network-access network-access? access-address access-protocol
            access-ports network-policy network-policy? policy-blocked
            policy-dns policy-public policy-exceptions policy-host
            policy-ingress restricted-network restricted-network?
            network-name network-backend network-bridge network-subnet
            network-gateway network-egress network-policy-of
            ipv4-range ipv4-overlap? validate-networks
            network-topology restricted-network-rules))

;; An endpoint is a destination for egress/host rules, or a SOURCE for
;; ingress rules.  In both cases ports are destination ports.
(define-record-type* <network-access>
  network-access make-network-access network-access?
  (address access-address)
  (protocol access-protocol (default 'tcp))
  (ports access-ports))

(define %non-public-ipv4
  '("0.0.0.0/8" "10.0.0.0/8" "100.64.0.0/10" "127.0.0.0/8"
    "169.254.0.0/16" "172.16.0.0/12" "192.0.0.0/24" "192.0.2.0/24"
    "192.168.0.0/16" "198.18.0.0/15" "198.51.100.0/24"
    "203.0.113.0/24" "224.0.0.0/4" "240.0.0.0/4"))

(define-record-type* <network-policy>
  network-policy make-network-policy network-policy?
  ;; Additional protected ranges; the baseline above cannot be removed.
  (blocked-destinations policy-blocked (default '()))
  (dns-servers policy-dns (default '()))
  ;; Protocol followed by destination ports, e.g. ((tcp 80 443)), or
  ;; ((tcp . all) (udp . all)) for public access on all ports.
  (public-egress policy-public (default '()))
  (forward-exceptions policy-exceptions (default '()))
  (host-services policy-host (default '()))
  (ingress policy-ingress (default '())))

(define-record-type* <restricted-network>
  restricted-network make-restricted-network restricted-network?
  (name network-name)
  (backend network-backend (default 'docker))
  (bridge network-bridge)
  (subnet network-subnet)
  (gateway network-gateway)
  ;; Empty means no initiated forwarding; #t permits any routed interface.
  (egress-interfaces network-egress (default '()))
  (policy network-policy-of (default (network-policy))))

(define (ipv4-range cidr)
  (let* ((parts (string-split cidr #\/))
         (ip (inet-pton AF_INET (car parts)))
         (prefix (if (= (length parts) 1) 32
                     (string->number (cadr parts)))))
    (unless (and (<= (length parts) 2) (integer? prefix)
                 (exact? prefix) (<= 0 prefix 32))
      (error "Invalid IPv4 prefix" cidr))
    (let* ((size (expt 2 (- 32 prefix)))
           (base (* (quotient ip size) size)))
      (cons base (+ base size -1)))))

(define (ipv4-overlap? left right)
  (let ((a (ipv4-range left)) (b (ipv4-range right)))
    (and (<= (car a) (cdr b)) (<= (car b) (cdr a)))))

(define (identifier? value limit)
  (and (string? value) (<= 1 (string-length value) limit)
       (not (char=? (string-ref value 0) #\-))
       (string-every (lambda (c)
                       (or (char<=? #\a c #\z) (char<=? #\A c #\Z)
                           (char<=? #\0 c #\9) (memv c '(#\_ #\-))))
                     value)))

(define (validate-ports protocol ports)
  (unless (and (memq protocol '(tcp udp))
               (or (eq? ports 'all)
                   (and (pair? ports) (list? ports)
                        (every (lambda (p) (and (integer? p) (exact? p)
                                                (<= 1 p 65535))) ports))))
    (error "Expected TCP/UDP and nonempty port list or all" protocol ports)))

(define (validate-access access)
  (unless (network-access? access) (error "Invalid endpoint" access))
  (ipv4-range (access-address access))
  (validate-ports (access-protocol access) (access-ports access)))

(define (validate-networks table networks)
  (unless (and (identifier? table 64)
               (not (char-numeric? (string-ref table 0))))
    (error "Invalid nftables table identifier" table))
  (unless (and (list? networks) (every restricted-network? networks))
    (error "Expected restricted networks" networks))
  (for-each
   (lambda (getter)
     (let ((values (map getter networks)))
       (unless (= (length values) (length (delete-duplicates values)))
         (error "Duplicate network name or bridge" values))))
   (list network-name network-bridge))
  (for-each
   (lambda (net)
     (unless (and (identifier? (network-name net) 63)
                  (identifier? (network-bridge net) 15)
                  (eq? (network-backend net) 'docker)
                  (or (eq? (network-egress net) #t)
                      (and (list? (network-egress net))
                           (every (lambda (i) (identifier? i 15))
                                  (network-egress net))
                           (not (member (network-bridge net)
                                        (network-egress net))))))
       (error "Invalid network identity, backend or egress" net))
     (let* ((cidr (network-subnet net))
            (range (ipv4-range cidr))
            (base (inet-pton AF_INET (car (string-split cidr #\/))))
            (gateway (inet-pton AF_INET (network-gateway net))))
       (unless (and (string-contains cidr "/") (= base (car range))
                    (< (car range) gateway (cdr range)))
         (error "Expected canonical subnet and usable gateway" net)))
     (for-each
      (lambda (other)
        (when (and (not (eq? net other))
                   (ipv4-overlap? (network-subnet net) (network-subnet other)))
          (error "Restricted subnets overlap" net other))) networks)
     (let ((policy (network-policy-of net)))
       (unless (network-policy? policy) (error "Invalid policy" policy))
       (for-each ipv4-range (policy-blocked policy))
       (unless (eq? (policy-dns policy) 'host)
         (for-each (lambda (ip) (inet-pton AF_INET ip)) (policy-dns policy)))
       (for-each (lambda (entry) (validate-ports (car entry) (cdr entry)))
                 (policy-public policy))
       (for-each validate-access
                 (append (policy-exceptions policy) (policy-host policy)
                         (policy-ingress policy))))) networks)
  #t)

(define (network-topology net)
  (list (network-name net) (network-backend net) (network-bridge net)
        (network-subnet net) (network-gateway net)))

(define (nft-set values)
  (string-append "{ " (string-join values ", ") " }"))

(define (quoted value) (format #f "~s" value))

(define (port-match protocol ports)
  (if (eq? ports 'all)
      (format #f "meta l4proto ~a" protocol)
      (format #f "~a dport ~a" protocol (nft-set (map number->string ports)))))

(define (endpoint-rule access field verdict)
  (format #f "  ip ~a ~a ~a counter ~a\n" field (access-address access)
          (port-match (access-protocol access) (access-ports access)) verdict))

(define (restricted-network-rules table networks)
  (validate-networks table networks)
  (define (dispatch direction suffix)
    (string-concatenate
     (map (lambda (net index)
            (format #f "  ~a ~s jump n~a_~a\n"
                    direction (network-bridge net) index suffix))
          networks (iota (length networks)))))
  (define (chains net index)
    (let* ((policy (network-policy-of net))
           (blocked (delete-duplicates
                     (append %non-public-ipv4 (policy-blocked policy)
                             (map network-subnet networks))))
           (source-guard
            (format #f "  meta nfproto != ipv4 counter drop\n  ip saddr != ~a counter drop\n  ct state invalid counter drop\n"
                    (network-subnet net))))
      (string-append
       (format #f " chain n~a_host {\n" index) source-guard
       "  ct direction reply ct state established,related return\n"
       (string-concatenate
        (map (lambda (a) (endpoint-rule a "daddr" "return")) (policy-host policy)))
       "  counter drop\n }\n"
       (format #f " chain n~a_out {\n" index) source-guard
       ;; Replies to authorized inbound flows do not need an egress grant.
       "  ct direction reply ct state established,related return\n"
       (cond ((eq? (network-egress net) #t) "")
             ((null? (network-egress net)) "  counter drop\n")
             (else
              (format #f "  oifname != ~a counter drop\n"
                      (nft-set (map quoted (network-egress net))))))
       (string-concatenate
        (map (lambda (a) (endpoint-rule a "daddr" "return"))
             (append (policy-exceptions policy)
                     (append-map
                      (lambda (ip)
                        (map (lambda (protocol)
                               (network-access (address ip) (protocol protocol)
                                               (ports '(53)))) '(tcp udp)))
                      (if (eq? (policy-dns policy) 'host)
                          '() (policy-dns policy))))))
       (if (eq? (policy-dns policy) 'host)
           "  ip daddr @host_dns udp dport 53 counter return\n  ip daddr @host_dns tcp dport 53 counter return\n"
           "")
       ;; Named interval sets with auto-merge accept nested/overlapping CIDRs.
       (format #f "  ip daddr @n~a_blocked counter drop\n" index)
       "  udp dport 53 counter drop\n  tcp dport 53 counter drop\n"
       (string-concatenate
        (map (lambda (entry)
               (format #f "  ~a counter return\n"
                       (port-match (car entry) (cdr entry)))) (policy-public policy)))
       "  counter drop\n }\n"
       (format #f " chain n~a_in {\n" index)
       (format #f "  meta nfproto != ipv4 counter drop\n  ip daddr != ~a counter drop\n  ct state invalid counter drop\n"
               (network-subnet net))
       "  ct state established,related return\n"
       (string-concatenate
        (map (lambda (a) (endpoint-rule a "saddr" "return")) (policy-ingress policy)))
       "  counter drop\n }\n"
       (format #f " set n~a_blocked {\n  type ipv4_addr; flags interval; auto-merge;\n  elements = ~a\n }\n"
               index (nft-set blocked)))))
  (string-append
   (format #f "add table inet ~a\nflush table inet ~a\ntable inet ~a {\n"
           table table table)
   (if (any (lambda (net) (eq? (policy-dns (network-policy-of net)) 'host))
            networks)
       " set host_dns { type ipv4_addr; }\n" "")
   (string-concatenate (map chains networks (iota (length networks))))
   " chain input {\n  type filter hook input priority -10; policy accept;\n"
   (dispatch "iifname" "host") " }\n"
   " chain forward {\n  type filter hook forward priority -10; policy accept;\n"
   ;; RETURN, not ACCEPT: an allowed source must still pass the destination.
   (dispatch "iifname" "out") (dispatch "oifname" "in") " }\n}\n"
   (format #f "add table ip ~a\nflush table ip ~a\ntable ip ~a {\n"
           table table table)
   " chain postrouting {\n  type nat hook postrouting priority srcnat; policy accept;\n"
   (string-concatenate
    (map (lambda (net)
           (if (eq? (network-egress net) #t)
               (format #f "  iifname ~s oifname != ~a ip saddr ~a masquerade\n"
                       (network-bridge net)
                       (nft-set (map (compose quoted network-bridge) networks))
                       (network-subnet net))
               (let ((external (lset-difference equal? (network-egress net)
                                                (map network-bridge networks))))
                 (if (null? external) ""
                     (format #f "  iifname ~s oifname ~a ip saddr ~a masquerade\n"
                             (network-bridge net) (nft-set (map quoted external))
                             (network-subnet net)))))) networks))
   " }\n}\n"))
