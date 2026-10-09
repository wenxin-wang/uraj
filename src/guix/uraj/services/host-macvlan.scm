;;; Run the host network on a fixed-MAC macvlan child.
(define-module (uraj services host-macvlan)
  #:use-module (gnu packages linux)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:export (host-macvlan-configuration host-macvlan-service-type))

(define-record-type* <host-macvlan-configuration>
  host-macvlan-configuration make-host-macvlan-configuration
  host-macvlan-configuration?
  (parent host-macvlan-parent (default "enp1s0"))
  (name host-macvlan-name (default "host0"))
  (mac host-macvlan-mac (default "02:31:00:00:00:02")))

(define (host-macvlan-start-program config)
  (program-file
   "host-macvlan-start"
   (with-imported-modules '((guix build utils))
     #~(begin
         (use-modules (guix build utils))
         (define ip #$(file-append iproute "/sbin/ip"))
         (define name #$(host-macvlan-name config))
         (define parent #$(host-macvlan-parent config))
         ;; Refuse an existing name; only clean up an interface we created.
         (invoke ip "link" "add" "link" parent
                 "name" name "address" #$(host-macvlan-mac config)
                 "type" "macvlan" "mode" "bridge")
         (catch #t
           (lambda ()
             (invoke ip "link" "set" "dev" parent "up")
             (invoke ip "link" "set" "dev" name "up"))
           (lambda args
             (system* ip "link" "delete" "dev" name)
             (apply throw args)))))))

(define (host-macvlan-services config)
  (list
   (shepherd-service
    (provision '(host-macvlan))
    (requirement '(user-processes udev))
    ;; The link remains a live resource until stop; one-shot would cause
    ;; every later dependent-service start to rerun interface creation.
    (documentation "Create the fixed-MAC host interface before DHCP starts.")
    (start #~(lambda _
              (zero? (system* #$(host-macvlan-start-program config)))))
    (stop #~(lambda _
             (unless (zero? (system* #$(file-append iproute "/sbin/ip")
                                    "link" "delete" "dev"
                                    #$(host-macvlan-name config)))
               (error "Could not remove host macvlan"))
             #f)))))

(define host-macvlan-service-type
  (service-type
   (name 'host-macvlan)
   (extensions
    (list (service-extension shepherd-root-service-type host-macvlan-services)))
   (default-value (host-macvlan-configuration))
   (description "Prepare a fixed-MAC host interface without assigning IP addresses.")))
