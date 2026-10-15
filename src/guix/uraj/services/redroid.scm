;;; Android instances, with Guix-owned firewall rules and persistent data.
(define-module (uraj services redroid)
  #:use-module (gnu services)
  #:use-module (gnu services containers)
  #:use-module (gnu services docker)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (guix modules)
  #:use-module (guix records)
  #:use-module (srfi srfi-1)
  #:use-module (uraj network-policy)
  #:use-module (uraj services restricted-network)
  #:use-module (uraj packages redroid)
  #:use-module (uraj services logs)
  #:export (%redroid-docker-configuration
            %redroid-network redroid-network
            redroid-configuration redroid-service-type
            redroid-container redroid-prepare-program))

(define %redroid-docker-configuration
  (docker-configuration
    (enable-iptables? #f)
    (enable-proxy? #f)
    ;; Guix passes iptables and userland-proxy as command-line arguments;
    ;; repeating them in daemon.json makes dockerd refuse to start.
    (config-file
     (plain-file "redroid-docker-daemon.json"
       "{\"bridge\":\"none\",\"ip6tables\":false,\"ip-forward\":false,\"ip-masq\":false}\n"))))

(define %redroid-network
  (restricted-network
    (name "redroid")
    (bridge "br-redroid")
    (subnet "10.203.0.0/24")
    (gateway "10.203.0.1")
    ;; Empty uplinks mean no outbound connections, not unrestricted access.
    (egress-interfaces '())
    (policy
     (network-policy
       (dns-servers '("114.114.114.114"))
       ;; Game traffic is not limited to HTTP.  Private destinations and
       ;; unsolicited inbound connections remain blocked on every port.
       (public-egress '((tcp . all) (udp . all)))))))

(define-record-type* <redroid-configuration>
  redroid-configuration make-redroid-configuration redroid-configuration?
  (name redroid-name (default "redroid-maa"))
  ;; Bootstrap tag: pin the working registry digest after device validation.
  (image redroid-image (default "docker.io/redroid/redroid:11.0.0-latest"))
  (data-directory redroid-data-directory (default "/var/lib/redroid/data/maa"))
  (network redroid-network (default %redroid-network))
  (address redroid-address (default "10.203.0.2"))
  (render-node redroid-render-node
               (default "/dev/dri/by-path/pci-0000:00:02.0-render"))
  ;; Enable after the first manual boot/scrcpy/game validation.
  (auto-start? redroid-auto-start? (default #f)))

(define (redroid-prepare-program config)
  (program-file (string-append (redroid-name config) "-prepare")
    (with-imported-modules
        (source-module-closure '((uraj build redroid))
          #:select? (lambda (module)
                      (or (guix-module-name? module)
                          (eq? (car module) 'uraj))))
      #~(begin
          (use-modules (uraj build redroid))
          (prepare-redroid #$(redroid-data-directory config)
                           #$(redroid-render-node config))))))

(define (redroid-dns-servers config)
  (let ((servers (policy-dns (network-policy-of (redroid-network config)))))
    ;; Android boot arguments need concrete addresses when the OCI command is
    ;; generated.  Host resolver snapshots are only available at service start.
    (unless (and (list? servers) (pair? servers))
      (error "Redroid requires an explicit nonempty IPv4 DNS server list" servers))
    (for-each (lambda (address) (inet-pton AF_INET address)) servers)
    servers))

(define (redroid-container config)
  (let ((dns (redroid-dns-servers config)))
    (oci-container-configuration
      (provision (redroid-name config))
      (image (redroid-image config))
      (network (network-name (redroid-network config)))
      (requirement
       (list 'restricted-network
             (string->symbol (string-append (redroid-name config) "-ready"))))
      (auto-start? (redroid-auto-start? config))
      (respawn? #t)
      (entrypoint "/redroid-init")
      (log-file (string-append "/var/log/" (redroid-name config) "/"
                               (redroid-name config) ".log"))
      ;; No ports, host networking, or Docker restart policy.  Shepherd owns
      ;; startup ordering, including after a daemon restart.
      (extra-arguments
       (append
        (append-map (lambda (address) (list "--dns" address))
                    dns)
        (list "--privileged" "--ip" (redroid-address config)
             ;; A static helper protects modprobe before Android's init starts.
             ;; OCI mounts below /proc are forbidden by runc; Android's shell
             ;; may need APEX libraries that are unavailable before init.
             "--mount" #~(string-append "type=bind,source="
                                        #$(file-append redroid-init "/bin/redroid-init")
                                        ",target=/redroid-init,readonly")
             "--mount" (string-append "type=bind,source=" (redroid-data-directory config)
                                      ",target=/data")
             "--mount" (string-append "type=bind,source=" (redroid-render-node config)
                                      ",target=/dev/dri/intel-render"))))
      (command
       (append
        (list "androidboot.hardware=redroid"
             "androidboot.use_memfd=true"
             "androidboot.redroid_width=1280"
             "androidboot.redroid_height=720"
             "androidboot.redroid_dpi=240"
             "androidboot.redroid_fps=30"
             "androidboot.redroid_gpu_mode=host"
             "androidboot.redroid_gpu_node=/dev/dri/intel-render"
             (string-append "androidboot.redroid_net_ndns="
                            (number->string (length dns))))
        (map (lambda (address index)
               (string-append "androidboot.redroid_net_dns" (number->string index)
                              "=" address))
             dns
             (iota (length dns) 1)))))))

(define redroid-service-type
  (service-type
    (name 'redroid)
    (extensions
     (list
      (service-extension restricted-network-service-type
        (lambda (config) (list (redroid-network config))))
      (service-extension oci-service-type
        (lambda (config) (oci-extension (containers (list (redroid-container config))))))
      (service-extension service-log-service-type
        (lambda (config) (list (service-log (name (redroid-name config))))))
      (service-extension shepherd-root-service-type
        (lambda (config)
          (list
           (shepherd-service
             (provision (list (string->symbol
                               (string-append (redroid-name config) "-ready"))))
             (requirement '(udev user-processes))
             (auto-start? (redroid-auto-start? config))
             (documentation "Check Binder and Intel rendering; prepare persistent Android data.")
             (start #~(lambda _ (invoke #$(redroid-prepare-program config)) #t))
             (stop #~(lambda _ #f))))))))
    (default-value (redroid-configuration))
    (description "Run a persistent redroid Android instance under the system OCI service.")))
