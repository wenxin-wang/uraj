;;; Android instances, with Guix-owned firewall rules and persistent data.
(define-module (uraj services redroid)
  #:use-module (gnu services)
  #:use-module (gnu services containers)
  #:use-module (gnu services docker)
  #:use-module (gnu services linux)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix records)
  #:use-module (srfi srfi-1)
  #:use-module (uraj utils gexp)
  #:use-module (uraj network-policy)
  #:use-module (uraj services restricted-network)
  #:use-module (uraj packages docker)
  #:use-module (uraj packages redroid)
  #:use-module (uraj services logs)
  #:export (%redroid-docker-configuration
            %redroid-network redroid-network
            redroid-configuration redroid-service-type
            redroid-container redroid-prepare-program
            redroid-image-tag redroid-image-context))

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
  ;; Official 13.0.0-latest, amd64 manifest checked on 2026-10-17.
  (image redroid-image
         (default "docker.io/redroid/redroid@sha256:524987f1fc489f6018e2c9d0dd622e5eccea13eb896417cb4bfb26bc3fea9afd"))
  (data-directory redroid-data-directory (default "/var/lib/redroid/data/maa"))
  (network redroid-network (default %redroid-network))
  (address redroid-address (default "10.203.0.2"))
  (render-node redroid-render-node
               (default "/dev/dri/by-path/pci-0000:00:02.0-render"))
  ;; A package with a system/ tree (e.g. redroid-ndk-translation) layered
  ;; onto IMAGE as a locally built image; #f runs IMAGE as is.
  (native-bridge redroid-native-bridge (default #f))
  ;; #f preserves the image's own properties. Explicit selection is needed
  ;; when replacing its bridge with a different implementation.
  (native-bridge-library redroid-native-bridge-library (default #f))
  ;; Enable after the first manual boot/scrcpy/game validation.
  (auto-start? redroid-auto-start? (default #f)))

(define (redroid-prepare-program config)
  (program-file (string-append (redroid-name config) "-prepare")
    (with-uraj-modules '((uraj build redroid))
      #~(begin
          (use-modules (uraj build redroid))
          (prepare-redroid #$(redroid-data-directory config)
                           #$(redroid-render-node config))))))

(define (redroid-image-tag config)
  ;; Local-only, readable name.  The image records its store context in a
  ;; label, which decides whether to rebuild; see ensure-redroid-image.
  (let* ((base (redroid-image config))
         (digest (cond ((string-contains base "@sha256:")
                        => (lambda (i) (substring base (+ i 8) (+ i 20))))
                       (else (error "Layered redroid needs a digest-pinned image"
                                    base))))
         (bridge (redroid-native-bridge config)))
    (string-append "localhost/uraj-redroid:" digest "-" (package-name bridge)
                   "-" (package-version bridge))))

(define (redroid-image-context config)
  (computed-file (string-append (redroid-name config) "-image-context")
    (with-imported-modules '((guix build utils))
      #~(begin
          (use-modules (guix build utils))
          (mkdir-p #$output)
          (copy-recursively #$(file-append (redroid-native-bridge config) "/system")
                            (string-append #$output "/system"))
          (let ((prepare #$(file-append (redroid-native-bridge config) "/prepare-image")))
            (when (file-exists? prepare)
              (copy-file prepare (string-append #$output "/prepare-image"))
              (copy-file #$(file-append redroid-build-tools "/bin/busybox")
                         (string-append #$output "/busybox")))
            (call-with-output-file (string-append #$output "/Dockerfile")
              (lambda (port)
                (format port "FROM ~a~%" #$(redroid-image config))
                (when (file-exists? prepare)
                  (display "USER 0
COPY busybox prepare-image /uraj-build-tools/
RUN [\"/uraj-build-tools/busybox\", \"sh\", \"/uraj-build-tools/prepare-image\"]
" port))
                (display "COPY system /system\n" port))))))))

(define (redroid-log-file config)
  (string-append "/var/log/" (redroid-name config) "/"
                 (redroid-name config) ".log"))

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
      (image (if (redroid-native-bridge config)
                 (redroid-image-tag config)
                 (redroid-image config)))
      (network (network-name (redroid-network config)))
      (entrypoint "/redroid-init")
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
        (list "qemu=1"
             "androidboot.hardware=redroid"
             "androidboot.use_memfd=true"
             "androidboot.redroid_width=1280"
             "androidboot.redroid_height=720"
             "androidboot.redroid_dpi=240"
             "androidboot.redroid_fps=30"
             "androidboot.redroid_gpu_mode=host"
             "androidboot.redroid_gpu_node=/dev/dri/intel-render"
             "androidboot.redroid_virtual_wifi=1"
             (string-append "androidboot.redroid_net_ndns="
                            (number->string (length dns))))
        (map (lambda (address index)
               (string-append "androidboot.redroid_net_dns" (number->string index)
                              "=" address))
             dns
             (iota (length dns) 1))
        (if (redroid-native-bridge-library config)
            (list
             (string-append "ro.dalvik.vm.native.bridge="
                            (redroid-native-bridge-library config))
             "persist.sys.nativebridge=1"
             "ro.product.cpu.abilist=x86_64,x86,arm64-v8a,armeabi-v7a,armeabi"
             "ro.product.cpu.abilist64=x86_64,arm64-v8a"
             "ro.product.cpu.abilist32=x86,armeabi-v7a,armeabi"
             "ro.dalvik.vm.isa.arm=x86" "ro.dalvik.vm.isa.arm64=x86_64")
            '()))))))

(define (redroid-ready-service-name config)
  (string->symbol (string-append (redroid-name config) "-ready")))

(define (redroid-run-program config)
  ;; The `docker run' that oci-service-type would generate for
  ;; redroid-container, preceded by what must hold before every run.
  (let ((container (redroid-container config))
        (docker (file-append docker-full "/bin/docker")))
    (program-file (string-append (redroid-name config) "-run")
      (with-uraj-modules '((uraj build redroid))
        #~(begin
            (use-modules (uraj build redroid))
            (prepare-redroid-container
             #$docker #$(redroid-name config)
             #:image #$(and (redroid-native-bridge config)
                            (redroid-image-tag config))
             #:context #$(and (redroid-native-bridge config)
                              (redroid-image-context config)))
            (execl #$docker "docker" "run" "--rm"
                   "--name" #$(redroid-name config)
                   "--entrypoint"
                   #$(oci-container-configuration-entrypoint container)
                   "--network"
                   #$(oci-container-configuration-network container)
                   #$@(oci-container-configuration-extra-arguments container)
                   #$(oci-container-configuration-image container)
                   #$@(oci-container-configuration-command container)))))))

(define (redroid-shepherd-service config)
  (shepherd-service
    (provision (list (string->symbol (redroid-name config))))
    (requirement (list 'dockerd 'user-processes 'restricted-network
                       (redroid-ready-service-name config)))
    (auto-start? (redroid-auto-start? config))
    (respawn? #t)
    (documentation "Run the redroid Android container.")
    (start #~(make-forkexec-constructor
              (list #$(redroid-run-program config))
              #:log-file #$(redroid-log-file config)))
    ;; Unlike oci-service-type's stop, wait for the removal, so that a
    ;; restart cannot race the old container for its name.
    (stop #~(lambda (pid)
              (system* #$(file-append docker-full "/bin/docker")
                       "rm" "--force" #$(redroid-name config))
              ((make-kill-destructor) pid)))))

(define redroid-service-type
  (service-type
    (name 'redroid)
    (extensions
     (list
      (service-extension restricted-network-service-type
        (lambda (config) (list (redroid-network config))))
      (service-extension service-log-service-type
        (lambda (config) (list (service-log (name (redroid-name config))))))
      ;; Android empties the modprobe sysctl, and vold only reads FUSE's
      ;; sysfs directory, which never triggers autoloading.
      (service-extension kernel-module-loader-service-type (const '("fuse")))
      (service-extension shepherd-root-service-type
        (lambda (config)
          (list
           (shepherd-service
             (provision (list (redroid-ready-service-name config)))
             (requirement '(udev user-processes kernel-module-loader))
             (auto-start? (redroid-auto-start? config))
             (documentation "Check Binder, FUSE and Intel rendering; prepare persistent Android data.")
             (start #~(lambda _ (invoke #$(redroid-prepare-program config)) #t))
             (stop #~(lambda _ #f)))
           (redroid-shepherd-service config))))))
    (default-value (redroid-configuration))
    (description "Run a persistent redroid Android instance with Docker.")))
