;;; Run from the repository root:
;;; GUILE_LOAD_PATH="$PWD/src/guix:$PWD/src/guile" guix time-machine \
;;;   -C env/guix/channels-lock.scm -- repl test/guix/uraj/system/zfs.scm
(use-modules (gnu)
             (gnu image)
             (gnu services)
             (gnu services shepherd)
             (gnu system image)
             (guix gexp)
             (srfi srfi-1)
             (srfi srfi-64))

(define (load-storie)
  (load (string-append (getcwd) "/env/guix/os/storie.scm")))

(define (shepherd-services os)
  (shepherd-configuration-services
   (service-value
    (fold-services (operating-system-services os)
                   #:target-type shepherd-root-service-type))))

(define (lookup services name)
  (find (lambda (s) (memq name (shepherd-service-provision s))) services))

(define (ancestors services name)
  (let walk ((pending (list name)) (seen '()))
    (if (null? pending)
        seen
        (let ((name (car pending)))
          (if (memq name seen)
              (walk (cdr pending) seen)
              (let ((service (lookup services name)))
                (unless service (error "Missing Shepherd dependency" name))
                (walk (append (shepherd-service-requirement service)
                              (cdr pending))
                      (cons name seen))))))))

(unsetenv "TO_ISO")
(define installed (shepherd-services (load-storie)))
(setenv "TO_ISO" "1")
(define live
  (shepherd-services
   (operating-system-for-image
    (os->image (load-storie) #:type (lookup-image-type-by-name 'iso9660)))))
(unsetenv "TO_ISO")

(test-begin "zfs-boot-independence")
(for-each
 (lambda (services)
   (for-each
    (lambda (name)
      (test-assert (format #f "~a is independent of failed ZFS" name)
        (not (any (lambda (dependency)
                    (memq dependency '(zfs-import zfs-mount file-system-zfs
                                       zfs-data-ready)))
                  (ancestors services name)))))
    '(user-processes networking ssh-daemon term-tty1 term-tty2
      term-tty3 term-tty4 term-tty5 term-tty6))
   (test-assert "ZFS import still starts automatically"
     (shepherd-service-auto-start? (lookup services 'zfs-import))))
 (list installed live))

(for-each
 (lambda (name)
   (test-assert (format #f "~a waits for actual data mounts" name)
     (memq 'zfs-data-ready (ancestors installed name))))
 '(nfs rpc.nfsd rpc.mountd rpc.statd zfs-scrub-core-data
   zfs-scrub-media-data zfs-snapshot-hourly zfs-snapshot-daily))
(test-assert "readiness waits for imports and mounting"
  (every (lambda (name) (memq name (ancestors installed 'zfs-data-ready)))
         '(zfs-import zfs-mount)))
(for-each (lambda (name)
            (test-assert (format #f "ISO does not run ~a" name)
              (not (lookup live name))))
          '(zfs-mount zfs-data-ready nfs rpc.mountd rpc.nfsd
            zfs-scrub-core-data zfs-scrub-media-data
            zfs-snapshot-hourly zfs-snapshot-daily))

;; Exercise the actual readiness predicate against a simulated mount table.
;; This gexp contains only literal dataset paths, so no store lowering is needed.
(define ready-module (make-fresh-user-module))
(module-use! ready-module (resolve-interface '(srfi srfi-1)))
(define mount-table '())
(module-define! ready-module 'mounts (lambda () mount-table))
(module-define! ready-module 'mount-source car)
(module-define! ready-module 'mount-point cadr)
(module-define! ready-module 'mount-type caddr)
(define ready?
  (eval (gexp->approximate-sexp
         (shepherd-service-start (lookup installed 'zfs-data-ready)))
        ready-module))
(define expected-mounts
  '(("core-data" "/core-data" "zfs")
    ("core-data/archive" "/core-data/archive" "zfs")
    ("core-data/backups" "/core-data/backups" "zfs")
    ("media-data" "/media-data" "zfs")))
(test-assert "no pools cannot enable exports" (not (ready?)))
(set! mount-table expected-mounts)
(test-assert "all expected datasets mounted" (ready?))
(for-each
 (lambda (missing)
   (set! mount-table (remove (lambda (entry) (equal? entry missing)) expected-mounts))
   (test-assert (format #f "missing ~a blocks exports" (car missing))
     (not (ready?))))
 expected-mounts)
(set! mount-table (cons '("core-data" "/core-data" "ext4") (cdr expected-mounts)))
(test-assert "wrong filesystem type blocks exports" (not (ready?)))
(set! mount-table (cons '("other-pool" "/core-data" "zfs") (cdr expected-mounts)))
(test-assert "wrong pool at export path blocks exports" (not (ready?)))
(set! mount-table (cons '("core-data" "/elsewhere" "zfs") (cdr expected-mounts)))
(test-assert "wrong mountpoint blocks exports" (not (ready?)))
(define failures (test-runner-fail-count (test-runner-current)))
(test-end "zfs-boot-independence")
(exit (if (zero? failures) 0 1))
