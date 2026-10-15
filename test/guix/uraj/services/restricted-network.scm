;;; guix repl -L src/guix -L src/guile test/guix/uraj/services/restricted-network.scm
(use-modules (gnu) (gnu services) (gnu services containers) (gnu services shepherd)
             (gnu services sysctl) (gnu system shadow) (srfi srfi-1) (srfi srfi-64)
             (uraj network-policy) (uraj services restricted-network)
             (uraj services redroid))

(test-begin "restricted-network-service")
(unsetenv "TO_ISO")
(define os (load (string-append (getcwd) "/env/guix/os/storie.scm")))
(define services (operating-system-services os))
(define config
  (service-value (fold-services services #:target-type restricted-network-service-type)))
(define agents (car (restricted-network-config-networks config)))
(test-equal "storie network name" "static-agent" (network-name agents))
(test-equal "storie bridge name" "br-static-agent" (network-bridge agents))
(test-equal "storie permits any routed interface" #t (network-egress agents))
(test-equal "storie inherits host DNS at service start" 'host
  (policy-dns (network-policy-of agents)))
(test-equal "table has no project prefix" "restricted_network"
  (restricted-network-config-table config))
(test-equal "only new-api is an internal forwarding exception" '("172.31.0.9")
  (map access-address (policy-exceptions (network-policy-of agents))))
(test-assert "no host or inbound grants"
  (and (null? (policy-host (network-policy-of agents)))
       (null? (policy-ingress (network-policy-of agents)))))
(define shepherd-services
  (shepherd-configuration-services
   (service-value (fold-services services #:target-type shepherd-root-service-type))))
(define network-service
  (find (lambda (s) (memq 'restricted-network (shepherd-service-provision s)))
        shepherd-services))
(test-equal "network waits for Docker, networking and forwarding"
  '(dockerd networking sysctl) (shepherd-service-requirement network-service))
(define sysctl
  (service-value (fold-services services #:target-type sysctl-service-type)))
(test-equal "Guix owns forwarding" "1"
  (assoc-ref (sysctl-configuration-settings sysctl) "net.ipv4.ip_forward"))
(define combined
  (service-value
   (fold-services
    (cons* (service subids-service-type)
           (service oci-service-type (oci-configuration (runtime 'docker)))
           (service redroid-service-type
             (redroid-configuration
               (network (restricted-network
                          (inherit %redroid-network)
                          (egress-interfaces '("host0"))))))
           services)
    #:target-type restricted-network-service-type)))
(test-equal "redroid contributes to the same owner" '("static-agent" "redroid")
  (map network-name (restricted-network-config-networks combined)))
(test-assert "combined policy validates"
  (validate-networks (restricted-network-config-table combined)
                     (restricted-network-config-networks combined)))
(define failures (test-runner-fail-count (test-runner-current)))
(test-end "restricted-network-service")
(exit (if (zero? failures) 0 1))
