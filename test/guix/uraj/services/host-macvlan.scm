;;; guix repl -L src/guix -L src/guile test/guix/uraj/services/host-macvlan.scm
(use-modules (gnu) (gnu services networking) (gnu services shepherd)
             (srfi srfi-1) (srfi srfi-13) (srfi srfi-64))
(unsetenv "TO_ISO")
(define os (load (string-append (getcwd) "/env/guix/os/storie.scm")))
(define all
  (shepherd-configuration-services
   (service-value (fold-services (operating-system-services os)
                                #:target-type shepherd-root-service-type))))
(define interface
  (find (lambda (s) (memq 'host-macvlan (shepherd-service-provision s))) all))
(define dhcp
  (service-value (fold-services (operating-system-services os)
                               #:target-type dhcpcd-service-type)))
(test-begin "host-macvlan")
(test-assert "host interface starts automatically"
  (shepherd-service-auto-start? interface))
(test-equal "interface does not depend on the DHCP service"
  '(user-processes udev) (shepherd-service-requirement interface))
(test-assert "DHCP waits for the host interface"
  (memq 'host-macvlan
        (shepherd-service-requirement
         (find (lambda (s) (memq 'networking (shepherd-service-provision s))) all))))
(test-assert "interface stays started across dependent-service restarts"
  (not (shepherd-service-one-shot? interface)))
(test-assert "DHCP excludes the physical parent"
  (string-contains (dhcpcd-configuration-extra-content dhcp)
                   "denyinterfaces enp1s0"))
(test-equal "DHCP only configures the host macvlan" '("host0")
  (dhcpcd-configuration-interfaces dhcp))
(test-assert "Paseo private network was not installed"
  (not (any (lambda (s) (memq 'paseo-network (shepherd-service-provision s))) all)))
(define failures (test-runner-fail-count (test-runner-current)))
(test-end "host-macvlan")
(exit (if (zero? failures) 0 1))
