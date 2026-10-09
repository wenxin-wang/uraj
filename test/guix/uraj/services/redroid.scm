;;; guix repl -L src/guix -L src/guile test/guix/uraj/services/redroid.scm
(use-modules (gnu) (gnu services) (gnu services containers)
             (gnu services docker) (gnu services shepherd) (gnu services sysctl)
             (gnu image) (gnu system image)
             (guix gexp) (json) (srfi srfi-1) (srfi srfi-64)
             (uraj build redroid) (uraj services redroid))

(test-begin "redroid")
(test-assert "enclosing VPN subnet conflicts"
  (ipv4-overlap? "10.203.0.0/24" "10.0.0.0/8"))
(test-assert "host route inside subnet conflicts"
  (ipv4-overlap? "10.203.0.0/24" "10.203.0.2"))
(test-assert "neighbor subnet does not conflict"
  (not (ipv4-overlap? "10.203.0.0/24" "10.203.1.0/24")))
(test-equal "ignore egress and own bridge, retain foreign local route"
  '((("dst" . "10.203.0.2") ("dev" . "vpn0")))
  (conflicting-routes
   '#((("dst" . "default") ("dev" . "wlan0"))
      (("dst" . "10.203.0.0/24") ("dev" . "br-redroid"))
      (("dst" . "10.203.0.2") ("dev" . "vpn0")))
   "10.203.0.0/24" "br-redroid"))

(define network
  '(("Name" . "redroid") ("Driver" . "bridge")
    ("Internal" . #f) ("EnableIPv6" . #f)
    ("Options" . (("com.docker.network.bridge.name" . "br-redroid")
                  ("com.docker.network.bridge.enable_ip_masquerade" . "false")))
    ("IPAM" . (("Config" . #((("Subnet" . "10.203.0.0/24")
                               ("Gateway" . "10.203.0.1"))))))))
(define (matches? net)
  (redroid-network-matches? net "redroid" "br-redroid" "10.203.0.0/24" "10.203.0.1"))
(test-assert "matching existing network may be reused" (matches? network))
(for-each
 (lambda (change)
   (test-assert (string-append "reject drift in " (car change))
     (not (matches? (cons change (alist-delete (car change) network equal?))))))
 '(("Driver" . "macvlan") ("EnableIPv6" . #t) ("Internal" . #t)
   ("Options" . (("com.docker.network.bridge.name" . "wrong")))
   ("IPAM" . (("Config" . #((("Subnet" . "10.204.0.0/24")
                              ("Gateway" . "10.204.0.1"))))))))

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
         '(redroid-network redroid-maa-ready sysctl udev dockerd)))
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
 '(containerd dockerd redroid-network redroid-maa redroid-maa-ready))

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

(define failures (test-runner-fail-count (test-runner-current)))
(test-end "redroid")
(exit (if (zero? failures) 0 1))
