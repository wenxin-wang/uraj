;;; guix repl -L src/guix -L src/guile test/guix/uraj/services/redroid.scm
(use-modules (gnu) (gnu services) (gnu services containers)
             (gnu services docker) (gnu services shepherd) (gnu services sysctl)
             (gnu image) (gnu system image)
             (guix gexp) (json) (srfi srfi-1) (srfi srfi-64)
             (guix packages)
             (uraj network-policy) (uraj packages redroid)
             (uraj services restricted-network) (uraj services redroid))

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
(test-assert "production Android starts automatically"
  (shepherd-service-auto-start? (lookup installed 'redroid-maa)))
(test-assert "layered image is built before the container starts"
  (memq 'redroid-maa-image (ancestors installed 'redroid-maa)))
(test-assert "image build waits for Docker and reruns on each start"
  (let ((image (lookup installed 'redroid-maa-image)))
    (and (memq 'dockerd (shepherd-service-requirement image))
         (shepherd-service-one-shot? image))))
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

(define production-config
  (service-value
   (find (lambda (s) (eq? (service-kind s) redroid-service-type))
         (operating-system-services installed-os))))
(define production-container (redroid-container production-config))
(test-assert "production explicitly selects Houdini and ARM64 mapping"
  (every (lambda (arg) (member arg (oci-container-configuration-command
                                   production-container)))
         '("qemu=1" "ro.dalvik.vm.native.bridge=libhoudini.so"
           "ro.dalvik.vm.isa.arm64=x86_64")))
(test-assert "Android 13 uses its own data directory"
  (member "type=bind,source=/var/lib/redroid/data/maa-houdini-13,target=/data"
          (oci-container-configuration-extra-arguments production-container)))
(test-assert "production does not request host ARM executable registration"
  (not (any (lambda (arg) (string-prefix? "ro.enable.native.bridge.exec" arg))
            (oci-container-configuration-command production-container))))

(define plain-container (redroid-container (redroid-configuration)))
(test-assert "without a native bridge the base image runs as is"
  (string-prefix? "docker.io/redroid/redroid@sha256:"
                  (oci-container-configuration-image plain-container)))
(define layered-config
  (redroid-configuration (native-bridge redroid-ndk-translation)))
(define layered-tag (redroid-image-tag layered-config))
(test-equal "layered tag names the base digest and bridge"
  (string-append "localhost/uraj-redroid:524987f1fc48-redroid-ndk-translation-"
                 (package-version redroid-ndk-translation))
  layered-tag)
(test-equal "container runs the layered tag" layered-tag
  (oci-container-configuration-image (redroid-container layered-config)))
(test-error "layering needs a digest-pinned base image" #t
  (redroid-image-tag
   (redroid-configuration
     (image "docker.io/redroid/redroid:11.0.0-latest")
     (native-bridge redroid-ndk-translation))))

;; A fake docker keeping one image: its label, set by the latest build.
(define fake (mkdtemp "/tmp/redroid-image-XXXXXX"))
(call-with-output-file (string-append fake "/docker")
  (lambda (port)
    (display "#!/bin/sh
d=${0%/*}
echo \"$*\" >> \"$d/log\"
case \"$1 $2\" in
  'image inspect')
    [ -f \"$d/label\" ] || exit 1
    case \"$4\" in *uraj.context*) cat \"$d/label\" ;; *) echo sha256:old ;; esac ;;
  'build '*) echo \"${5#uraj.context=}\" > \"$d/label\" ;;
esac\n" port)))
(chmod (string-append fake "/docker") #o700)
(define (fake-count prefix)
  (count (lambda (line) (string-prefix? prefix line))
         (string-split (call-with-input-file (string-append fake "/log")
                         (@ (ice-9 textual-ports) get-string-all))
                       #\newline)))
(define (ensure-fake context)
  ((@ (uraj build redroid) ensure-redroid-image)
   (string-append fake "/docker") "localhost/t:1" context))
(ensure-fake "/gnu/store/a-ctx")
(ensure-fake "/gnu/store/a-ctx")
(test-equal "missing tag is built once, then reused" 1 (fake-count "build "))
(test-equal "first build has no image to replace" 0 (fake-count "image rm"))
(ensure-fake "/gnu/store/b-ctx")
(test-equal "changed context rebuilds the same tag" 2 (fake-count "build "))
(test-equal "replaced image is removed" 1 (fake-count "image rm"))
(ensure-fake "/gnu/store/b-ctx")
(test-equal "rebuilt image is then reused" 2 (fake-count "build "))
((@ (guix build utils) delete-file-recursively) fake)

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
