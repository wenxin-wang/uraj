;;; guix repl -L src/guix -L src/guile test/guix/uraj/services/redroid.scm
(use-modules (gnu) (gnu services) (gnu services containers)
             (gnu services docker) (gnu services shepherd) (gnu services sysctl)
             (gnu image) (gnu system image)
             (guix gexp) (json) (srfi srfi-1) (srfi srfi-64)
             (uraj network-policy) (uraj services restricted-network)
             (uraj services redroid))

(test-begin "redroid")
(test-assert "prepare program carries its local module and Guix dependencies"
  (let ((modules (gexp-modules
                  (program-file-gexp
                   (redroid-prepare-program (redroid-configuration))))))
    (every (lambda (module) (member module modules))
           '((uraj build redroid) (guix build utils)))))
(define (load-hypie)
  (load (string-append (getcwd) "/env/guix/os/hypie.scm")))
(define (services os)
  (shepherd-configuration-services
   (service-value (fold-services (operating-system-services os)
                                #:target-type shepherd-root-service-type))))
(define (lookup all name)
  (find (lambda (s) (memq name (shepherd-service-provision s))) all))
(define (ancestors all name)
  (let walk ((pending (list name)) (seen '()))
    (if (null? pending) seen
        (let ((name (car pending)))
          (if (memq name seen) (walk (cdr pending) seen)
              (let ((s (lookup all name)))
                (unless s (error "Missing service dependency" name))
                (walk (append (shepherd-service-requirement s) (cdr pending))
                      (cons name seen))))))))
(unsetenv "TO_ISO")
(define installed-os (load-hypie))
(define installed (services installed-os))
(test-assert "Android waits for networking, firewall, sysctl, devices and Docker"
  (every (lambda (r) (memq r (ancestors installed 'redroid-maa)))
         '(restricted-network redroid-maa-ready sysctl udev dockerd)))
(test-assert "Android is independent of data pools and VPN secrets"
  (not (any (lambda (r) (memq r '(zfs-data-ready zfs-mount sops-secrets vpn-fwd2home)))
            (ancestors installed 'redroid-maa))))
(test-assert "first Android boot is explicit"
  (not (shepherd-service-auto-start? (lookup installed 'redroid-maa))))
(define sysctl
  (service-value (fold-services (operating-system-services installed-os)
                               #:target-type sysctl-service-type)))
(test-equal "Guix enables forwarding" "1"
  (assoc-ref (sysctl-configuration-settings sysctl) "net.ipv4.ip_forward"))
(setenv "TO_ISO" "1")
(define live (services (operating-system-for-image
                        (os->image (load-hypie)
                                   #:type (lookup-image-type-by-name 'iso9660)))))
(unsetenv "TO_ISO")
(for-each
 (lambda (name)
   (test-assert (format #f "installer omits ~a" name) (not (lookup live name))))
 '(containerd dockerd restricted-network redroid-maa redroid-maa-ready))

(define restricted
  (service-value (fold-services (operating-system-services installed-os)
                                #:target-type restricted-network-service-type)))
(test-equal "hypie routes bridges ahead of fwd2home's rule" 200
  (restricted-network-config-vpn-bypass-priority restricted))
(define redroid-policy
  (network-policy-of (car (restricted-network-config-networks restricted))))
(test-equal "redroid uses the common firewall" "restricted_network"
  (restricted-network-config-table restricted))
(test-equal "game protocols are not limited to HTTP" '((tcp . all) (udp . all))
  (policy-public redroid-policy))
(test-assert "no redroid LAN, host or inbound exceptions"
  (every null? (list (policy-exceptions redroid-policy)
                     (policy-host redroid-policy) (policy-ingress redroid-policy))))

(define container (redroid-container (redroid-configuration)))
(test-assert "no published ADB port"
  (null? (oci-container-configuration-ports container)))
(test-assert "no Docker restart bypass"
  (not (member "--restart" (oci-container-configuration-extra-arguments container))))
(test-equal "container has an isolated network" "redroid"
  (oci-container-configuration-network container))
(test-assert "no OCI bind mounts at forbidden proc paths"
  (not (any (lambda (arg) (and (string? arg) (string-contains arg "target=/proc/")))
            (oci-container-configuration-extra-arguments container))))
(test-assert "wrapper preserves the image hardware parameter"
  (member "androidboot.hardware=redroid"
          (oci-container-configuration-command container)))
(test-equal "wrapper runs before Android without APEX dependencies" "/redroid-init"
  (oci-container-configuration-entrypoint container))

(define custom-network
  (restricted-network
    (inherit %redroid-network)
    (name "android-test") (bridge "br-android-test")
    (subnet "10.207.0.0/24") (gateway "10.207.0.1")
    (egress-interfaces #t)
    (policy (network-policy
              (inherit (network-policy-of %redroid-network))
              (dns-servers '("172.31.0.53" "172.31.0.54"))
              (public-egress '((tcp 443)))))))
(define custom-config
  (redroid-configuration (network custom-network) (address "10.207.0.2")))
(define custom-container (redroid-container custom-config))
(define custom-restricted
  (service-value
   (fold-services
    (map (lambda (entry)
           (if (eq? (service-kind entry) redroid-service-type)
               (service redroid-service-type custom-config)
               entry))
         (operating-system-services installed-os))
    #:target-type restricted-network-service-type)))
(test-eq "service contributes the embedded network unchanged" custom-network
  (car (restricted-network-config-networks custom-restricted)))
(test-equal "container uses the embedded network name" "android-test"
  (oci-container-configuration-network custom-container))
(test-equal "Docker DNS comes from the network policy"
  '("--dns" "172.31.0.53" "--dns" "172.31.0.54" "--privileged" "--ip" "10.207.0.2")
  (take (oci-container-configuration-extra-arguments custom-container) 7))
(test-equal "Android DNS comes from the same network policy"
  '("androidboot.redroid_net_ndns=2"
    "androidboot.redroid_net_dns1=172.31.0.53"
    "androidboot.redroid_net_dns2=172.31.0.54")
  (filter (lambda (arg) (string-prefix? "androidboot.redroid_net_" arg))
          (oci-container-configuration-command custom-container)))
(for-each
 (lambda (dns)
   (test-error "reject DNS that cannot populate Android boot arguments" #t
     (redroid-container
      (redroid-configuration
        (network (restricted-network
                   (inherit %redroid-network)
                   (policy (network-policy (dns-servers dns)))))))))
 '(host () ("::1") ("invalid")))

(define failures (test-runner-fail-count (test-runner-current)))
(test-end "redroid")
(exit (if (zero? failures) 0 1))
