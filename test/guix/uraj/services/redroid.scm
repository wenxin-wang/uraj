;;; guix repl -L src/guix -L src/guile test/guix/uraj/services/redroid.scm
(use-modules (gnu) (gnu services) (gnu services containers)
             (gnu services docker) (gnu services shepherd) (gnu services sysctl)
             (gnu image) (gnu system image)
             (guix gexp) (json) (srfi srfi-1) (srfi srfi-64)
             (uraj network-policy) (uraj services restricted-network)
             (uraj services redroid))

(test-begin "redroid")
(define (load-hypie)
  ;; Deployment is intentionally commented out in hypie.scm.  Exercise an
  ;; opted-in installed-system fixture without enabling it on the real host.
  (let ((os (load (string-append (getcwd) "/env/guix/os/hypie.scm"))))
    (if (getenv "TO_ISO") os
        (operating-system
          (inherit os)
          (services
           (append
            (list (service containerd-service-type)
                  (service docker-service-type %redroid-docker-configuration)
                  (service oci-service-type (oci-configuration (runtime 'docker)))
                  (service restricted-network-service-type)
                  (service redroid-network-service-type
                    (redroid-network-configuration (egress-interfaces '("uplink"))))
                  (service redroid-service-type))
            (operating-system-user-services os)))))))
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
         '(restricted-network redroid-network redroid-maa-ready sysctl udev dockerd)))
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
 '(containerd dockerd restricted-network redroid-network redroid-maa redroid-maa-ready))

(define restricted
  (service-value (fold-services (operating-system-services installed-os)
                                #:target-type restricted-network-service-type)))
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

(define failures (test-runner-fail-count (test-runner-current)))
(test-end "redroid")
(exit (if (zero? failures) 0 1))
