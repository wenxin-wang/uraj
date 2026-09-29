;;; iso.scm -- turn a machine operating-system into a live installer.

(define-module (uraj system iso)
  #:use-module (gnu)
  #:use-module (gnu bootloader)
  #:use-module (gnu bootloader grub)
  #:use-module (gnu packages version-control)
  #:use-module (gnu services base)
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

(define* (iso-services os #:optional (key "/etc/guix/signing-key.pub"))
  ;; Read only the public key of the machine evaluating the image.  Keep this
  ;; inside the ISO transformation: installed OS evaluations must neither
  ;; read nor authorize the build host's key.
  (let ((host-keys (if (file-exists? key)
                       (list (local-file key "build-host-signing-key.pub"))
                       '())))
    (cons ((@@ (gnu system install) cow-store-service))
          (modify-services (operating-system-user-services os)
            (guix-service-type config =>
              (guix-configuration
                (inherit config)
                (discover? #t)
                (authorized-keys
                 (append host-keys
                         (guix-configuration-authorized-keys config)))))))))

(define (to-iso os)
  "Return a live installation image operating system derived from OS.

Machine-specific kernel, firmware, initrd, services, and packages are kept;
only settings tied to an installed system's disks and authentication are
replaced, and the standard Guix installation utilities are added.  The live
daemon discovers LAN substitutes and trusts the build host's public key
when it exists."
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
    (services (iso-services os))

    (packages
     (append (list git)
             (@@ (gnu system install) %installer-disk-utilities)
             (operating-system-packages os)))))
