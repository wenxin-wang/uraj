;;; guix repl -L src/guix test/guix/uraj/restricted-network-runtime.scm
(use-modules (guix build utils) (ice-9 textual-ports) (json)
             (srfi srfi-1) (srfi srfi-64)
             (uraj network-policy)
             (uraj build restricted-network))

(test-begin "restricted-network-runtime")
(define temporary (mkdtemp "/tmp/restricted-runtime-XXXXXX"))
(define tools (string-append temporary "/tools"))
(mkdir tools)
(for-each
 (lambda (name)
   (let ((path (string-append tools "/" name)))
     (copy-file "test/guix/uraj/restricted-network-command.sh" path)
     (chmod path #o700))) '("docker" "nft" "ip"))
(define topology '("static-agent" docker "br-policy-test" "10.204.0.0/24" "10.204.0.1"))
(define network
  '#((("Name" . "static-agent") ("Driver" . "bridge")
      ("Internal" . #f) ("EnableIPv6" . #f)
      ("Options" . (("com.docker.network.bridge.name" . "br-policy-test")
                    ("com.docker.network.bridge.enable_ip_masquerade" . "false")))
      ("IPAM" . (("Config" . #((("Subnet" . "10.204.0.0/24")
                                 ("Gateway" . "10.204.0.1")))))))))
(define (fixture name)
  (let ((dir (string-append temporary "/" name)))
    (mkdir dir)
    (call-with-output-file (string-append dir "/network.json")
      (lambda (port) (scm->json network port)))
    (setenv "RESTRICTED_MOCK_DIR" dir)
    (unsetenv "RESTRICTED_MOCK_FAILURE")
    dir))
(define* (ensure dir #:optional (topologies (list topology))
                 #:key (bypass 200))
  (ensure-restricted-networks
   (string-append tools "/docker") (string-append tools "/nft")
   (string-append tools "/ip") "/unused-test-rules.nft"
   "restricted_network" topologies '()
   #:vpn-bypass-priority bypass
   #:state-directory (string-append dir "/state")))
(define (log dir)
  (call-with-input-file (string-append dir "/log") get-string-all))
(define (state dir)
  (call-with-input-file (string-append dir "/state/topology.scm") read))
(define clean (fixture "clean"))
(test-assert "initial provisioning" (begin (ensure clean) #t))
(test-assert "load firewall before creating network"
  (< (string-contains (log clean) "nft --file")
     (string-contains (log clean) "docker network create")))
(test-equal "persist topology" (list "restricted_network" (list topology)) (state clean))
(test-assert "repeated start" (begin (ensure clean) #t))
(test-equal "network created only once" 1
  (count (lambda (line) (string-prefix? "docker network create" line))
         (string-split (log clean) #\newline)))
;; strongSwan's full tunnel (from all lookup 220) would otherwise capture it.
(define (bypass-adds dir)
  (count (lambda (line)
           (string=? line "ip -4 rule add pref 200 to 10.204.0.0/24 lookup main"))
         (string-split (log dir) #\newline)))
(test-equal "bypass rule added only once" 1 (bypass-adds clean))
(test-assert "bypass rule added after firewall load"
  (< (string-contains (log clean) "nft --file")
     (string-contains (log clean) "ip -4 rule add")))
;; As printed by `ip -j -4 rule show pref 200' (iproute2 7.0).
(test-equal "own bypass rule recognized" "10.204.0.0/24"
  (bypass-rule-subnet '(("priority" . 200) ("src" . "all")
                        ("dst" . "10.204.0.0") ("dstlen" . 24)
                        ("table" . "main"))))
(test-assert "source-restricted rule is not a bypass"
  (not (bypass-rule-subnet '(("priority" . 200) ("src" . "172.31.0.7")
                             ("srclen" . 32) ("dst" . "10.204.0.0")
                             ("dstlen" . 24) ("table" . "main")))))
(define foreign (fixture "foreign-rule"))
(call-with-output-file (string-append foreign "/rules.json")
  (lambda (port)
    (display "[{\"priority\":200,\"src\":\"all\",\"dst\":\"10.204.0.0\",\"dstlen\":24,\"table\":\"220\"}]" port)))
(test-error "foreign rule at bypass priority aborts" #t (ensure foreign))
(test-equal "foreign rule is not overridden" 0 (bypass-adds foreign))
(define hijacked (fixture "hijacked"))
(call-with-output-file (string-append hijacked "/route-hijacked") (const #t))
(test-error "subnet not routed through its bridge aborts" #t (ensure hijacked))
(define no-bypass (fixture "no-bypass"))
(test-assert "provisioning without VPN bypass" (begin (ensure no-bypass #:bypass #f) #t))
(test-equal "no routing rule without VPN bypass" 0 (bypass-adds no-bypass))
(define hijacked-no-bypass (fixture "hijacked-no-bypass"))
(call-with-output-file (string-append hijacked-no-bypass "/route-hijacked") (const #t))
(test-error "capture is still detected without VPN bypass" #t
  (ensure hijacked-no-bypass #:bypass #f))
(test-error "removal rejected before commands" #t (ensure clean '()))
(test-equal "failed removal retains state"
  (list "restricted_network" (list topology)) (state clean))
(for-each
 (lambda (failure)
   (let ((dir (fixture failure)))
     (setenv "RESTRICTED_MOCK_FAILURE" failure)
     (test-error (string-append failure " failure aborts") #t (ensure dir))
     (test-assert (string-append failure " failure creates no network")
       (not (file-exists? (string-append dir "/exists"))))))
 '("docker" "check" "load"))
(define retry (string-append temporary "/load"))
(test-equal "load failure reserves topology for retry"
  (list "restricted_network" (list topology)) (state retry))
(unsetenv "RESTRICTED_MOCK_FAILURE")
(test-assert "retry after failed load succeeds" (begin (ensure retry) #t))
(define dns (fixture "dns"))
(mkdir (string-append dns "/lo"))
(define resolver (string-append dns "/resolv.conf"))
(define (write-text file contents)
  (call-with-output-file file (lambda (port) (display contents port))))
(write-text resolver "# DHCP\nsearch home\nnameserver 172.31.0.1 # gateway\nnameserver 172.31.0.1\nnameserver 10.0.0.53\n")
(test-equal "parse and deduplicate upstream resolvers"
  '("172.31.0.1" "10.0.0.53") (read-host-dns resolver))
(define mixed-resolver
  "nameserver 2001:db8::53\nnameserver 172.31.0.1\nnameserver fe80::1%host0\nnameserver 172.31.0.1\n")
(write-text resolver mixed-resolver)
(test-equal "dual-stack host DNS keeps IPv4 and skips IPv6 including scoped entries"
  '("172.31.0.1") (read-host-dns resolver))
(for-each
 (lambda (contents)
   (write-text resolver contents)
   (test-error "reject missing, stub, IPv6 or malformed upstream DNS" #t
     (read-host-dns resolver)))
 '("search home\n" "nameserver 127.0.0.53\n" "nameserver ::1\n"
   "nameserver 2001:db8::53\nnameserver fe80::1%host0\n"
   "nameserver 172.31.0.1 extra\n" "nameserver invalid\n"
   "nameserver 172.31.0.1\nnameserver invalid\n"
   "nameserver 172.31.0.1\nnameserver invalid::ip\n"
   "nameserver 172.31.0.1\nnameserver 127.0.0.53\n"))
(test-error "missing resolver file rejected" #t
  (read-host-dns (string-append dns "/missing")))
(write-text resolver "nameserver 172.31.0.1\n")
(test-error "valid resolver alone does not mean networking is ready" #t
  (wait-for-host-dns (string-append tools "/ip") '("lo") resolver #:attempts 1))
(test-error "any egress still waits for a default route" #t
  (wait-for-host-dns (string-append tools "/ip") #t resolver #:attempts 1))
(define (failure-details thunk)
  (catch #t
    (lambda () (thunk) "")
    (lambda (key . args) (format #f "~s" (cons key args)))))
(test-assert "timeout explains missing default route"
  (string-contains
   (failure-details
    (lambda ()
      (wait-for-host-dns (string-append tools "/ip") #t resolver #:attempts 1)))
   "No default IPv4 route on an allowed egress interface"))
(test-equal "wait for DHCP route before taking snapshot" '("172.31.0.1")
  (wait-for-host-dns (string-append tools "/ip") '("lo") resolver
    #:attempts 2
    #:pause (lambda (_) (write-text (string-append dns "/route-ready") ""))))
(test-equal "any egress accepts the available route" '("172.31.0.1")
  (wait-for-host-dns (string-append tools "/ip") #t resolver #:attempts 1))
(test-error "empty egress grants no routed DNS" #t
  (wait-for-host-dns (string-append tools "/ip") '() resolver #:attempts 1))
(test-error "explicit egress rejects a route through another interface" #t
  (wait-for-host-dns (string-append tools "/ip") '("other") resolver #:attempts 1))
(write-text resolver "")
(test-assert "timeout preserves the resolver failure"
  (string-contains
   (failure-details
    (lambda ()
      (wait-for-host-dns (string-append tools "/ip") #t resolver #:attempts 1)))
   "No IPv4 nameservers in host resolver file"))
(test-equal "wait for DNS after route appears" '("172.31.0.1")
  (wait-for-host-dns (string-append tools "/ip") '("lo") resolver
    #:attempts 2
    #:pause (lambda (_) (write-text resolver "nameserver 172.31.0.1\n"))))
(define rules (string-append dns "/template.nft"))
(write-text rules
  (restricted-network-rules "restricted_network"
    (list (restricted-network
            (name "static-agent") (bridge "br-policy-test")
            (subnet "10.204.0.0/24") (gateway "10.204.0.1")
            (egress-interfaces '("lo"))
            (policy (network-policy (dns-servers 'host)))))))
(define* (ensure-dns #:optional (any-egress? #f))
  (ensure-restricted-networks
   (string-append tools "/docker") (string-append tools "/nft")
   (string-append tools "/ip") rules "restricted_network" (list topology)
   (if any-egress? '() '("lo"))
   #:any-egress? any-egress?
   #:state-directory (string-append dns "/state")
   #:interface-directory dns
   #:runtime-directory (string-append dns "/run")
   #:inherit-host-dns? #t #:resolv-conf resolver #:dns-attempts 1))
(define snapshot (string-append dns "/run/resolv.conf"))
(write-text resolver mixed-resolver)
(test-assert "provision using host DNS" (begin (ensure-dns) #t))
(test-equal "publish resolver snapshot" "nameserver 172.31.0.1\n"
  (call-with-input-file snapshot get-string-all))
(test-assert "firewall transaction uses same resolver"
  (string-contains
   (call-with-input-file (string-append dns "/state/rules.nft.new") get-string-all)
   "add element inet restricted_network host_dns { 172.31.0.1 }"))
(write-text resolver "nameserver 10.0.0.53\n")
(test-equal "host edits do not change running snapshot" "nameserver 172.31.0.1\n"
  (call-with-input-file snapshot get-string-all))
(setenv "RESTRICTED_MOCK_FAILURE" "load")
(test-error "failed DNS reload aborts" #t (ensure-dns))
(test-equal "failed reload preserves published snapshot" "nameserver 172.31.0.1\n"
  (call-with-input-file snapshot get-string-all))
(unsetenv "RESTRICTED_MOCK_FAILURE")
(ensure-dns #t)
(test-equal "next successful start refreshes DNS" "nameserver 10.0.0.53\n"
  (call-with-input-file snapshot get-string-all))
(define failures (test-runner-fail-count (test-runner-current)))
(test-end "restricted-network-runtime")
;; Only this freshly created directory is removed; real state is never used.
(delete-file-recursively temporary)
(exit (if (zero? failures) 0 1))
