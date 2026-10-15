;;; One firewall owner, multiple declarative restricted networks.
(define-module (uraj services restricted-network)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (gnu services sysctl)
  #:use-module (gnu packages guile)
  #:use-module (gnu packages linux)
  #:use-module (guix gexp)
  #:use-module (guix modules)
  #:use-module (guix records)
  #:use-module (srfi srfi-1)
  #:use-module (uraj network-policy)
  #:use-module (uraj packages docker)
  #:export (restricted-network-configuration restricted-network-service-type
            restricted-network-config-table restricted-network-config-networks
            restricted-network-firewall-file restricted-network-program))

(define-record-type* <restricted-network-configuration>
  restricted-network-configuration make-restricted-network-configuration
  restricted-network-configuration?
  (table-name restricted-network-config-table (default "restricted_network"))
  (networks restricted-network-config-networks (default '())))

(define (restricted-network-firewall-file config)
  (plain-file "restricted-network.nft"
    (restricted-network-rules (restricted-network-config-table config)
                              (restricted-network-config-networks config))))

(define (restricted-network-program config)
  (let ((networks (restricted-network-config-networks config)))
    (program-file "restricted-network-ensure"
      (with-extensions (list guile-json-4)
        (with-imported-modules
            ;; The default selector only includes guix/gnu modules.
            (source-module-closure '((uraj build restricted-network))
              #:select? (lambda (module)
                          (or (guix-module-name? module)
                              (eq? (car module) 'uraj))))
          #~(begin
              (use-modules (uraj build restricted-network))
              (ensure-restricted-networks
               #$(file-append docker-full "/bin/docker")
               #$(file-append nftables "/sbin/nft")
               #$(file-append iproute "/sbin/ip")
               #$(restricted-network-firewall-file config)
               #$(restricted-network-config-table config)
               '#$(map network-topology networks)
               '#$(delete-duplicates
                    (append-map (lambda (net)
                                  (let ((egress (network-egress net)))
                                    (if (eq? egress #t) '() egress)))
                                networks))
               #:any-egress?
               #$(any (lambda (net) (eq? (network-egress net) #t)) networks)
               #:inherit-host-dns?
               #$(any (lambda (net)
                        (eq? (policy-dns (network-policy-of net)) 'host))
                      networks))))))))

(define (restricted-network-shepherd-services config)
  (list
   (shepherd-service
     (provision '(restricted-network))
     (requirement '(dockerd networking sysctl))
     (documentation "Prepare restricted Docker networks and their firewall.")
     (start #~(lambda _ (invoke #$(restricted-network-program config)) #t))
     ;; Protection must survive a dependent service stopping or reconfiguration.
     (stop #~(lambda _ #f))
     (actions (list (shepherd-configuration-action
                     (restricted-network-firewall-file config)))))))

(define restricted-network-service-type
  (service-type
    (name 'restricted-network)
    (extensions
     (list
      (service-extension profile-service-type (const (list nftables)))
      (service-extension sysctl-service-type
                         (const '(("net.ipv4.ip_forward" . "1"))))
      (service-extension shepherd-root-service-type
                         restricted-network-shepherd-services)))
    ;; Applications can contribute network declarations with simple-service.
    (compose concatenate)
    (extend (lambda (config networks)
              (restricted-network-configuration
                (inherit config)
                (networks (append (restricted-network-config-networks config)
                                  networks)))))
    (default-value (restricted-network-configuration))
    (description "Guix-owned restricted networks, filtering and IPv4 NAT.")))
