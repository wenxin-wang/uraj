;;; Shared LAN network, independent of application Compose lifecycles.
(define-module (uraj services docker-lan)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:use-module (guix modules)
  #:use-module (gnu packages guile)
  #:use-module (uraj packages docker)
  #:export (docker-lan-configuration docker-lan-service-type))

(define-record-type* <docker-lan-configuration>
  docker-lan-configuration make-docker-lan-configuration docker-lan-configuration?
  ;; Retain the existing Immich network so migration need not disconnect it.
  (name docker-lan-name (default "docker_lan"))
  (parent docker-lan-parent (default "enp1s0"))
  (subnet docker-lan-subnet (default "172.31.0.0/24"))
  (gateway docker-lan-gateway (default "172.31.0.1"))
  ;; Keep automatic allocation constrained; applications use explicit IPs.
  (ip-range docker-lan-ip-range (default "172.31.0.6/32")))

(define (docker-lan-services config)
  (let ((ensure
         (program-file
          "docker-lan-ensure"
          (with-extensions (list guile-json-4)
            (with-imported-modules (source-module-closure '((guix build utils)))
              #~(begin
                  (use-modules (guix build utils) (ice-9 popen) (json))
                  (define docker #$(file-append docker-full "/bin/docker"))
                  (define name #$(docker-lan-name config))
                  (setenv "DOCKER_HOST" "unix:///var/run/docker.sock")
                  (unless (file-exists?
                           #$(string-append "/sys/class/net/" (docker-lan-parent config)))
                    (error "Docker LAN parent interface is missing"))
                  (unless (zero? (system* docker "network" "inspect" name))
                    (invoke docker "network" "create" "--driver" "macvlan"
                            "--opt" #$(string-append "parent=" (docker-lan-parent config))
                            "--opt" "macvlan_mode=bridge"
                            "--subnet" #$(docker-lan-subnet config)
                            "--gateway" #$(docker-lan-gateway config)
                            "--ip-range" #$(docker-lan-ip-range config) name))
                  ;; Refuse an incompatible existing network; never replace
                  ;; one that may still carry live Immich traffic.
                  (let* ((pipe (open-pipe* OPEN_READ docker "network" "inspect" name))
                         (net (vector-ref (json->scm pipe) 0))
                         (status (close-pipe pipe))
                         (options (assoc-ref net "Options"))
                         (ipam (assoc-ref (assoc-ref net "IPAM") "Config")))
                    (unless (and (zero? status)
                                 (equal? (assoc-ref net "Driver") "macvlan")
                                 (equal? (assoc-ref options "parent")
                                         #$(docker-lan-parent config))
                                 (member (assoc-ref options "macvlan_mode") '(#f "bridge"))
                                 (= (vector-length ipam) 1)
                                 (equal? (assoc-ref (vector-ref ipam 0) "Subnet")
                                         #$(docker-lan-subnet config))
                                 (equal? (assoc-ref (vector-ref ipam 0) "Gateway")
                                         #$(docker-lan-gateway config))
                                 (equal? (assoc-ref (vector-ref ipam 0) "IPRange")
                                         #$(docker-lan-ip-range config)))
                      (error "Existing Docker LAN does not match configuration" name)))))))))
    (list (shepherd-service
           (provision '(docker-lan))
           (requirement '(dockerd networking))
           (documentation "Ensure the shared macvlan LAN exists.")
           (start #~(lambda _ (invoke #$ensure) #t))
           ;; Network ownership belongs to the system, not a Compose project.
           (stop #~(lambda _ #f))))))

(define docker-lan-service-type
  (service-type
   (name 'docker-lan)
   (extensions (list (service-extension shepherd-root-service-type docker-lan-services)))
   (default-value (docker-lan-configuration))
   (description "Maintain a shared Docker macvlan network without deleting live networks.")))
