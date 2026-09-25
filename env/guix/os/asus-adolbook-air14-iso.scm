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
;;; amdgpu is not blacklisted here: amdgpu.dcdebugmask disables PSR and
;;; Panel Replay before the driver probes.  The older post-probe debugfs
;;; service is deliberately disabled below while this approach is tested.
;;; Without either workaround the screen freezes on the first frame
;;; rendered after the driver loads -- the system then looks hung or the
;;; keyboard dead -- and a manual "modprobe.blacklist=amdgpu,radeon" at
;;; the GRUB prompt used to be the only way to get a usable console.
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
 ;; Guix does not add the resume argument itself; the initrd resumes
 ;; from a device given as path, UUID, or bare label.
 (kernel-arguments
  (append %default-kernel-arguments
          %asus-adolbook-air14-kernel-cmdlines))
 (initrd (asus-adolbook-air14-acpi-hack
          (operating-system-initrd desktop-iso-os)))

  ;; amdgpu.dcdebugmask above now disables PSR and Panel Replay before
  ;; the driver probes.  Leave the old post-probe debugfs workaround out
  ;; of this image while testing whether the kernel argument is sufficient.
  ;;
  ;; (services
  ;;  (append (operating-system-user-services desktop-iso-os)
  ;;          (list %asus-adolbook-air14-panel-replay-service)))
 )
