;;; desktop-iso.scm -- live installation image for Guix System.
;;;
;;; Build (needs this repo checked out: -L makes the uraj channel
;;; modules visible; see the build-iso command in maak.scm):
;;;   guix time-machine --channels=env/guix/channels-lock.scm -- \
;;;     system image -t iso9660 -L src/guix env/guix/os/desktop-iso.scm
;;;   sudo dd if=<image.iso> of=/dev/<usb> bs=4M conv=fsync status=progress
;;;
;;; Access:
;;;   ssh wenxin@<host>            (authorized key only)
;;;   local login: wenxin, empty password (VT1 starts the niri session
;;;   after login, VT2-6 are plain shells); "sudo" works with a bare
;;;   RET at the prompt.
;;;
;;; The live system is %desktop-base-os (users, SSH, greetd, Guix Home)
;;; minus the real-disk parts, plus the installer tooling below.
;;;
;;; No real-device mounts and no (swap-devices) here: the image
;;; machinery supplies the ISO's own volatile root, and the target
;;; machine's disk layout belongs to the target's config ("guix system
;;; init" uses it).  See lappie.scm's header for the mount recipe.
;;;
;;; The live system's guix only knows the default channel.  Before
;;; "guix system init" with a config that uses nonguix/rosenthal/uraj
;;; modules, pull the repo's channels on the live system first:
;;;   guix pull -C /path/to/repo/env/guix/channels.scm
;;; and add a local (channel (name 'uraj) (url "/path/to/repo/src/guix"))
;;; entry if the config imports (uraj ...) modules.

(use-modules (gnu)
             (gnu bootloader)
             (gnu bootloader grub)
             (gnu packages version-control)  ;git
             (guix gexp)
             (nongnu system linux-initrd)    ;microcode-initrd
             (uraj system base))

;;; nonguix's combined-initrd names its output "initrd.img"; the iso9660
;;; zisofs filter in (gnu build image) only excludes "*.gz" among
;;; initrd-ish names, so the ISO's initrd.img would be zisofs-compressed
;;; and GRUB would feed the raw compressed bytes to the kernel ("rootfs
;;; image is not initramfs ... looks like an initrd" panic).  Copying it
;;; to a ".gz"-named output makes the filter leave it uncompressed.
(define desktop-initrd
  (lambda (file-systems . rest)
    (computed-file "combined-initrd.gz"
      (with-imported-modules '((guix build utils))
        #~(begin
            (use-modules (guix build utils))
            (copy-file #$(apply microcode-initrd file-systems rest)
                       #$output))))))

(operating-system
  (inherit %desktop-base-os)
  (host-name "guix-installer")

  (initrd desktop-initrd)

  ;; The image machinery swaps in grub-mkrescue for iso9660; this
  ;; declaration only provides defaults, it targets no real disk.
  (bootloader
   (bootloader-configuration
    (bootloader grub-bootloader)))

  ;; Pseudo file systems only: the ISO's volatile root comes from the
  ;; image machinery.
  (file-systems %base-file-systems)
  (swap-devices '())

  ;; %installer-disk-utilities is not exported from (gnu system
  ;; install), hence @@; it is the official installer's disk tool set
  ;; (parted, gptfdisk, dosfstools, btrfs-progs, e2fsprogs, cryptsetup,
  ;; mdadm, lvm2, ...).  Everything else -- niri, greetd, the Guix Home
  ;; environment, dbus -- comes from %desktop-base-os.
  (packages
   (append (list git)
           (@@ (gnu system install) %installer-disk-utilities)
           (operating-system-packages %desktop-base-os))))
