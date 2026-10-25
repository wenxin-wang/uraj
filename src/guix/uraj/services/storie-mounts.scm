;;; On-demand access to the NAS; no remote mount in the boot dependency graph.
(define-module (uraj services storie-mounts)
  #:use-module (gnu packages nfs)
  #:use-module (gnu services)
  #:use-module (gnu services nfs)
  #:use-module (guix gexp)
  #:export (storie-mounts-services))

(define %shares '("core-data" "media-data"))

(define %mount-root "/mnt/storie")

;; Guix writes direct autofs entries into auto.master itself, which automount
;; rejects, so mount an indirect map and link storie's paths to it.
(define storie-mounts-links-activation
  #~(for-each
     (lambda (share)
       (let* ((link (string-append "/" share))
              (target (string-append #$%mount-root "/" share))
              (pivot (string-append link ".new")))
         (unless (equal? target (false-if-exception (readlink link)))
           (catch #t
             (lambda ()
               ;; Replace an empty mount point left by an older generation.
               (let ((st (false-if-exception (lstat link))))
                 (when (and st (eq? 'directory (stat:type st)))
                   (rmdir link)))
               (false-if-exception (delete-file pivot))
               (symlink target pivot)
               (rename-file pivot link))
             (lambda args
               (format (current-error-port)
                       "warning: cannot link ~a to ~a: ~s~%"
                       link target args))))))
     '#$%shares))

(define storie-mounts-services
  (list
   ;; libmount looks for mount.nfs4 and umount.nfs4 in the system profile;
   ;; Guix's setuid programs only provide mount.nfs.
   (simple-service 'storie-mounts-nfs-helpers profile-service-type
                   (list nfs-utils))
   (simple-service 'storie-mounts-links activation-service-type
                   storie-mounts-links-activation)
   (service autofs-service-type
     (autofs-configuration
       (timeout 300)
       (mount-wait 30)
       (negative-timeout 10)
       (mounts
        (list
         (autofs-indirect-map
           (mount-point %mount-root)
           (entries
            (map (lambda (share)
                   (autofs-map-entry
                     ;; Unlike "nfs", this type adds no rpc.statd requirement.
                     (type "nfs4")
                     ;; Use IPv4: storie's exports allow only the home /24.
                     (device (string-append "172.31.0.5:/" share))
                     (mount-point share)
                     ;; Keep hard retries for data integrity after mounting.
                     (options '(rw (vers . "4.2") (proto . tcp)
                                   (sec . sys) hard nosuid nodev))))
                 %shares)))))))))
