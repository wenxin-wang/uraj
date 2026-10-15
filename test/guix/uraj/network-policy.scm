;;; guix repl -L src/guix test/guix/uraj/network-policy.scm [OUTPUT.nft]
(use-modules (uraj network-policy) (uraj build restricted-network)
             (uraj build restricted-network-docker)
             (uraj services redroid)
             (srfi srfi-1) (srfi srfi-64))

(test-begin "network-policy")
(define agents
  (restricted-network
    (name "static-agent") (bridge "br-static-agent")
    (subnet "10.204.0.0/24") (gateway "10.204.0.1")
    (egress-interfaces '("uplink" "br-code"))
    (policy
     (network-policy
       (dns-servers '("9.9.9.9"))
       (public-egress '((tcp 80 443)))
       (forward-exceptions
        (list (network-access (address "172.31.0.9") (ports '(3000)))
              (network-access (address "10.205.0.2") (ports '(8000)))))
       (host-services
        (list (network-access (address "10.204.0.1") (ports '(8080)))))))))
(define code
  (restricted-network
    (name "code") (bridge "br-code")
    (subnet "10.205.0.0/24") (gateway "10.205.0.1")
    (egress-interfaces '("uplink"))))
(define networks (list agents code))
(test-assert "valid policy" (validate-networks "restricted_network" networks))
(define agents-any-egress
  (restricted-network (inherit agents) (egress-interfaces #t)))
(define agents-no-egress
  (restricted-network (inherit agents) (egress-interfaces '())))
(test-assert "any and empty egress validate"
  (and (validate-networks "restricted_network" (list agents-any-egress code))
       (validate-networks "restricted_network" (list agents-no-egress code))))
(for-each
 (lambda (egress)
   (test-error "reject invalid egress selector" #t
     (validate-networks "restricted_network"
       (list (restricted-network (inherit agents) (egress-interfaces egress))))))
 '(#f "uplink" ("uplink" . "br-code") ("bad*")))
(test-error "reject duplicate bridge" #t
  (validate-networks "restricted_network" (list agents agents)))
(test-error "reject overlapping subnets" #t
  (validate-networks "restricted_network"
    (list agents (restricted-network (inherit code)
                  (subnet "10.204.0.0/25") (gateway "10.204.0.1")))))
(test-error "reject table injection" #t (validate-networks "bad; flush ruleset" networks))
(test-error "reject interface injection" #t
  (validate-networks "restricted_network"
    (list (restricted-network (inherit agents) (bridge "br-*")))))
(test-error "reject subnet with host bits" #t
  (validate-networks "restricted_network"
    (list (restricted-network (inherit agents) (subnet "10.204.0.3/24")))))
(test-error "reject network address as gateway" #t
  (validate-networks "restricted_network"
    (list (restricted-network (inherit agents) (gateway "10.204.0.0")))))
(test-error "reject unsupported backend" #t
  (validate-networks "restricted_network"
    (list (restricted-network (inherit agents) (backend 'netns)))))
(test-error "reject port injection" #t
  (validate-networks "restricted_network"
    (list (restricted-network (inherit agents)
            (policy (network-policy (public-egress '((tcp "80; accept")))))))))
(test-error "reject IPv6 until implemented" #t
  (validate-networks "restricted_network"
    (list (restricted-network (inherit agents)
            (policy (network-policy (dns-servers '("::1"))))))))
(test-assert "CIDR containing subnet overlaps"
  (ipv4-overlap? "10.0.0.0/8" "10.204.0.0/24"))
(test-equal "foreign local route conflicts, defaults and own route do not"
  '((("dst" . "10.204.0.7") ("dev" . "vpn0")))
  (conflicting-routes
   '#((("dst" . "default") ("dev" . "uplink"))
      (("dst" . "10.204.0.0/24") ("dev" . "br-static-agent"))
      (("dst" . "10.204.0.7") ("dev" . "vpn0")))
   (network-topology agents)))
(define previous (list "restricted_network" (list (network-topology agents))))
(test-assert "allow policy changes and new networks"
  (begin (check-topology-transition previous "restricted_network"
                                    (map network-topology networks)) #t))
(test-error "refuse removed network" #t
  (check-topology-transition previous "restricted_network" '()))
(test-error "refuse renamed table" #t
  (check-topology-transition previous "other" (map network-topology networks)))
(test-error "refuse renumbering" #t
  (check-topology-transition previous "restricted_network"
    '(("static-agent" docker "br-static-agent" "10.206.0.0/24" "10.206.0.1"))))

(define docker-net
  '(("Name" . "static-agent") ("Driver" . "bridge")
    ("Internal" . #f) ("EnableIPv6" . #f)
    ("Options" . (("com.docker.network.bridge.name" . "br-static-agent")
                  ("com.docker.network.bridge.enable_ip_masquerade" . "false")))
    ("IPAM" . (("Config" . #((("Subnet" . "10.204.0.0/24")
                               ("Gateway" . "10.204.0.1"))))))))
(test-assert "reuse exact Docker network"
  (docker-network-matches? docker-net (network-topology agents)))
(for-each
 (lambda (change)
   (test-assert (string-append "reject drift: " (car change))
     (not (docker-network-matches?
           (cons change (alist-delete (car change) docker-net equal?))
           (network-topology agents)))))
 '(("Driver" . "macvlan") ("EnableIPv6" . #t) ("Internal" . #t)
   ("Options" . (("com.docker.network.bridge.name" . "wrong")))))

(define rules (restricted-network-rules "restricted_network" networks))
(test-assert "no global flush" (not (string-contains rules "flush ruleset")))
(test-assert "source rules return for destination checks"
  (string-contains rules "tcp dport { 8000 } counter return"))
(test-assert "no cross-network NAT"
  (not (string-contains rules "oifname { \"uplink\", \"br-code\" } ip saddr")))
(test-assert "empty configuration generates valid tables"
  (string? (restricted-network-rules "restricted_network" '())))
(define code-with-ingress
  (restricted-network
    (inherit code)
    (policy (network-policy
              (ingress (list (network-access (address "10.204.0.0/24")
                                             (ports '(8000)))))))))
(define agents-with-redroid-policy
  (restricted-network
    (inherit agents)
    (egress-interfaces '("uplink"))
    (policy (network-policy-of
             (redroid-restricted-network
              (redroid-network-configuration (dns "9.9.9.9")))))))
(when (> (length (command-line)) 1)
  (for-each
   (lambda (entry)
     (call-with-output-file (string-append (cadr (command-line)) (car entry))
       (lambda (p) (display (cdr entry) p))))
   (list (cons "" rules)
         (cons ".any-egress" (restricted-network-rules "restricted_network"
                              (list agents-any-egress code)))
         (cons ".any-egress-ingress"
               (restricted-network-rules "restricted_network"
                 (list agents-any-egress code-with-ingress)))
         (cons ".no-egress" (restricted-network-rules "restricted_network"
                             (list agents-no-egress code-with-ingress)))
         (cons ".ingress" (restricted-network-rules "restricted_network"
                           (list agents code-with-ingress)))
         (cons ".redroid" (restricted-network-rules "restricted_network"
                           (list agents-with-redroid-policy code)))
         (cons ".host-dns"
               (string-append
                (restricted-network-rules "restricted_network"
                  (list (restricted-network
                          (inherit agents)
                          (policy (network-policy
                                    (inherit (network-policy-of agents))
                                    (dns-servers 'host)))) code))
                "add element inet restricted_network host_dns { 172.31.0.10 }\n")))))
(define failures (test-runner-fail-count (test-runner-current)))
(test-end "network-policy")
(exit (if (zero? failures) 0 1))
