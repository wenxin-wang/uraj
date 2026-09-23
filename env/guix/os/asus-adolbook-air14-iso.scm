;;; asus-adolbook-air14-iso.scm -- live installation image for the ASUS
;;; Adol Book Air 14, which only boots with the patched SSDT10 of
;;; (uraj hardware asus): its firmware table panics acpi_init right
;;; after GRUB, so nothing but "acpi=off" comes up -- and then the
;;; internal keyboard and the touchpad are dead.  Everything else comes
;;; from desktop-iso.scm.
;;;
;;; Build (same command as desktop-iso.scm, see its header):
;;;   guix time-machine --channels=env/guix/channels-lock.scm -- \
;;;     system image -t iso9660 -L src/guix env/guix/os/asus-adolbook-air14-iso.scm
;;;
;;; Boot without "acpi=off" and verify the table was replaced:
;;;   dmesg | grep "Table Upgrade"    -> override [SSDT-AMD    -AOD     ]
;;;   dmesg | grep "ACPI: SSDT.*AOD"  -> OEM revision 00000002
;;;
;;; The override is ignored while the kernel is locked down, so do not
;;; enable Secure Boot for this image.

(use-modules (gnu)
             (uraj hardware asus))

;; desktop-iso.scm is a config file, not a module: evaluate it to get the
;; <operating-system> to inherit from.  Guix loads config files by absolute
;; path, so current-filename resolves no matter where guix is invoked from.
(define desktop-iso-os
  (load (in-vicinity (dirname (current-filename)) "desktop-iso.scm")))

(operating-system
  (inherit desktop-iso-os)
  (initrd (asus-adolbook-air14-acpi-hack
           (operating-system-initrd desktop-iso-os))))
