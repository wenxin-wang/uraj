;;; Shared Btrfs root layout; provisioning is a separate, manual operation.
(define-module (uraj system storage)
  #:use-module (gnu)
  #:use-module (ice-9 match)
  #:use-module (uraj system base)
  #:export (btrfs-root-file-systems %nvme-swap-devices))

(define (btrfs-root-file-systems label)
  (append
   (list %tmp-file-system
         (file-system
           (device (file-system-label "EFI"))
           (mount-point "/boot/efi")
           (type "vfat")))
   (map (match-lambda
          ((mount-point subvol)
           (file-system
             (device (file-system-label label))
             (mount-point mount-point)
             (type "btrfs")
             (options
              (string-append "subvol=" subvol
                             (if (string=? subvol "@snapshots")
                                 "" ",compress=zstd"))))))
        '(("/" "@root") ("/home" "@home") ("/var" "@var")
          ("/gnu/store" "@gnu") ("/data" "@data")
          ("/snapshots" "@snapshots")))
   %base-file-systems))

(define %nvme-swap-devices
  (list (swap-space
          (target (file-system-label "swap"))
          (discard? #t))))
