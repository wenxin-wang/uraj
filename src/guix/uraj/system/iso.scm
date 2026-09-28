;;; iso.scm -- turn a machine operating-system into a live installer.

(define-module (uraj system iso)
  #:use-module (gnu)
  #:use-module (gnu bootloader)
  #:use-module (gnu bootloader grub)
  #:use-module (gnu packages version-control)
  #:use-module (guix gexp)
  #:export (to-iso))

(define %iso-tmp-file-system
  (file-system
    (mount-point "/tmp")
    (device "none")
    (type "tmpfs")
    (flags '(no-suid no-dev))
    (options "mode=1777,size=16G")
    (check? #f)
    (create-mount-point? #t)))

;;; iso9660's zisofs filter does not recognize nonguix's "initrd.img" as an
;;; initrd and compresses it.  GRUB then passes compressed bytes to the
;;; kernel.  Give any machine-specific initrd (including wrappers around
;;; microcode-initrd) a .gz output name so the filter leaves it alone.
(define (iso-initrd base-initrd)
  (lambda (file-systems . rest)
    (computed-file "live-initrd.gz"
      (with-imported-modules '((guix build utils))
        #~(begin
            (use-modules (guix build utils))
            (copy-file #$(apply base-initrd file-systems rest) #$output))))))

(define (to-iso os)
  "Return a live installation image operating system derived from OS.

Machine-specific kernel, firmware, initrd, services, and packages are kept;
only settings tied to an installed system's disks and authentication are
replaced, and the standard Guix installation utilities are added."
  (operating-system
    (inherit os)

    (initrd (iso-initrd (operating-system-initrd os)))

    ;; The iso9660 image machinery replaces this with grub-mkrescue.  This
    ;; declaration supplies defaults without referring to a real disk.
    (bootloader
     (bootloader-configuration
      (bootloader grub-bootloader)))

    ;; The image supplies its own volatile root.  A separate /tmp matches the
    ;; official installer and keeps the sticky permissions expected below.
    (file-systems
     (cons %iso-tmp-file-system %base-file-systems))
    (swap-devices '())

    ;; A live image is disposable and requires a usable empty-password login.
    (pam-services (base-pam-services #:allow-empty-passwords? #t))

    ;; After mounting the target at /mnt, run:
    ;;   sudo install -d -m 1777 /mnt/tmp
    ;;   sudo herd start cow-store /mnt
    (services
     (cons ((@@ (gnu system install) cow-store-service))
           (operating-system-user-services os)))

    (packages
     (append (list git)
             (@@ (gnu system install) %installer-disk-utilities)
             (operating-system-packages os)))))
