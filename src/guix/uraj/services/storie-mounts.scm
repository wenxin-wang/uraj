;;; On-demand access to the NAS; no remote mount in the boot dependency graph.
(define-module (uraj services storie-mounts)
  #:use-module (gnu services)
  #:use-module (gnu services nfs)
  #:export (storie-mounts-service))

(define storie-mounts-service
  (service autofs-service-type
    (autofs-configuration
      (timeout 300)
      (mount-wait 30)
      (negative-timeout 10)
      (mounts
       (list
        (autofs-indirect-map
          (mount-point "/mnt/storie")
          (entries
           (map (lambda (share)
                  (autofs-map-entry
                    ;; NFSv4 needs no NFSv3 rpc.statd service.
                    (type "nfs4")
                    ;; Use IPv4: storie's exports allow only the home /24.
                    (device (string-append "172.31.0.5:/" share))
                    (mount-point share)
                    ;; Keep hard retries for data integrity after mounting.
                    (options '(rw (vers . "4.2") (proto . tcp)
                                  (sec . sys) hard nosuid nodev))))
                '("core-data" "media-data")))))))))
