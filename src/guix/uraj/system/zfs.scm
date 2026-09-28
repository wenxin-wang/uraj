;;; ZFS data storage must not gate access to a Btrfs-root system.
(define-module (uraj system zfs)
  #:use-module (gnu services)
  #:use-module (gnu services nfs)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (rosenthal services file-systems)
  #:use-module (srfi srfi-1)
  #:export (zfs-data-service-type
            zfs-data-ready-service
            nfs-on-zfs-service-type))

;; Preserve Rosenthal's module, udev, package, import and mount support, but
;; leave user-processes independent of data disks.  This is for ZFS DATA
;; pools only: a ZFS root needs the original filesystem boot dependencies.
(define zfs-data-service-type
  (service-type
    (inherit zfs-service-type)
    (name 'zfs-data)
    (extensions
     (remove (lambda (extension)
               (eq? (service-extension-target extension)
                    user-processes-service-type))
             (service-type-extensions zfs-service-type)))))

(define (zfs-data-ready-service datasets)
  "Require each (DATASET . MOUNT-POINT) in DATASETS to be mounted as ZFS.
A successful import/mount-all alone does not prove that every pool exists."
  (simple-service 'zfs-data-ready shepherd-root-service-type
    (list
     (shepherd-service
       (provision '(zfs-data-ready))
       (requirement '(file-system-zfs))
       (documentation "Verify the ZFS datasets needed by data services.")
       (modules '((guix build syscalls) (srfi srfi-1)))
       (start
        #~(lambda ()
            (let ((current-mounts (mounts)))
              (every
               (lambda (dataset)
                 (or (any (lambda (entry)
                            (and (string=? (mount-source entry) (car dataset))
                                 (string=? (mount-point entry) (cdr dataset))
                                 (string=? (mount-type entry) "zfs")))
                          current-mounts)
                     (begin
                       (format (current-error-port)
                               "ZFS dataset ~a is not mounted at ~a; data services remain stopped.~%"
                               (car dataset) (cdr dataset))
                       #f)))
               '#$datasets))))
       (stop #~(const #f))))))

;; Gate all NFS server components, including mountd, before they can serve
;; exports.  rpcbind and the rest of networking remain independent of ZFS.
(define nfs-on-zfs-service-type
  (service-type
    (inherit nfs-service-type)
    (name 'nfs-on-zfs)
    (extensions
     (map (lambda (extension)
            (if (eq? (service-extension-target extension)
                     shepherd-root-service-type)
                (service-extension
                 shepherd-root-service-type
                 (lambda (config)
                   (map (lambda (service)
                          (shepherd-service
                            (inherit service)
                            (requirement
                             (cons 'zfs-data-ready
                                   (shepherd-service-requirement service)))))
                        ((service-extension-compute extension) config))))
                extension))
          (service-type-extensions nfs-service-type)))))
