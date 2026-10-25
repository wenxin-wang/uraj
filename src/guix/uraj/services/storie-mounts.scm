;;; On-demand access to the NAS; no remote mount in the boot dependency graph.
(define-module (uraj services storie-mounts)
  #:use-module (gnu packages nfs)
  #:use-module (gnu services)
  #:use-module (gnu services nfs)
  #:export (storie-mounts-services))

(define storie-mounts-services
  (list
   ;; libmount looks for mount.nfs4 and umount.nfs4 in the system profile;
   ;; Guix's setuid programs only provide mount.nfs.
   (simple-service 'storie-mounts-nfs-helpers profile-service-type
                   (list nfs-utils))
   (service autofs-service-type
     (autofs-configuration
       (timeout 300)
       (mount-wait 30)
       (negative-timeout 10)
       (mounts
        ;; Direct entries keep the same paths as on storie.
        (map (lambda (share)
               (autofs-map-entry
                 ;; Unlike "nfs", this type adds no rpc.statd requirement.
                 (type "nfs4")
                 ;; Use IPv4: storie's exports allow only the home /24.
                 (device (string-append "172.31.0.5:/" share))
                 (mount-point (string-append "/" share))
                 ;; Keep hard retries for data integrity after mounting.
                 (options '(rw (vers . "4.2") (proto . tcp)
                               (sec . sys) hard nosuid nodev))))
             '("core-data" "media-data")))))))
