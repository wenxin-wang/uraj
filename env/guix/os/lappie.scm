;;; lappie.scm -- Guix System configuration for the development laptop.
;;;
;;; Everything shared with other personal machines (user, SSH, greetd,
;;; Guix Home, desktop services) lives in (uraj system desktop); this file
;;; only adds lappie's disk layout, its boot specifics, and the hardware
;;; workarounds of the Adol Book Air 14 (see (uraj hardware asus)): the
;;; ACPI table override its firmware needs to boot at all, and the Panel
;;; Replay workaround its eDP panel needs to stay alive under amdgpu.
;;;
;;; Disk layout (btrfs + EFI + swap).  All file systems are referenced
;;; by label, so /dev/nvme0n1 can be anything.
;;;
;;;   nvme0n1p1  ESP    vfat   /boot/efi   label "EFI"
;;;   nvme0n1p2  swap   swap               label "swap"  (size >= RAM,
;;;                                       hibernation image goes here)
;;;   nvme0n1p3  btrfs                     label "lappie"
;;;     @root       -> /
;;;     @home       -> /home
;;;     @var        -> /var
;;;     @gnu        -> /gnu/store
;;;     @data       -> /data
;;;     @snapshots  -> /snapshots
;;;
;;; Partitioning recipe (sgdisk):
;;;   sgdisk --zap-all /dev/nvme0n1
;;;   sgdisk -n 1:0:+1G  -t 1:ef00 -c 1:EFI    /dev/nvme0n1
;;;   sgdisk -n 2:0:+16G -t 2:8200 -c 2:swap   /dev/nvme0n1   ; >= 2/5RAM
;;;   sgdisk -n 3:0:0    -t 3:8300 -c 3:lappie /dev/nvme0n1
;;;   mkfs.fat -F32 -n EFI /dev/nvme0n1p1
;;;   mkswap -L swap /dev/nvme0n1p2
;;;   mkfs.btrfs -L lappie /dev/nvme0n1p3
;;;   mount /dev/nvme0n1p3 /mnt
;;;   for s in root home var gnu data snapshots; do
;;;     btrfs subvolume create /mnt/@$s
;;;   done
;;;   umount /mnt
;;;
;;; Mount everything under /mnt before "guix system init": init writes
;;; into /mnt blindly, so the store must land on @gnu (an empty @gnu
;;; would hide it at boot) and the ESP must be reachable for the
;;; bootloader.
;;;   mount -o subvol=@root,compress=zstd /dev/nvme0n1p3 /mnt
;;;   mkdir -p /mnt/boot/efi /mnt/home /mnt/var /mnt/gnu/store \
;;;            /mnt/data /mnt/snapshots
;;;   mount -o subvol=@home,compress=zstd /dev/nvme0n1p3 /mnt/home
;;;   mount -o subvol=@var,compress=zstd  /dev/nvme0n1p3 /mnt/var
;;;   mount -o subvol=@gnu,compress=zstd  /dev/nvme0n1p3 /mnt/gnu/store
;;;   mount -o subvol=@data,compress=zstd /dev/nvme0n1p3 /mnt/data
;;;   mount -o subvol=@snapshots          /dev/nvme0n1p3 /mnt/snapshots
;;;   mount /dev/nvme0n1p1 /mnt/boot/efi

(use-modules (gnu)
             (gnu bootloader)
             (gnu bootloader grub)
             (srfi srfi-1)
             (uraj hardware asus)
             (uraj system desktop))

(define %btrfs-mount-options "compress=zstd")

(define (btrfs-subvolume mount-point subvol)
  (file-system
   (device (file-system-label "lappie"))
   (mount-point mount-point)
   (type "btrfs")
   (options (string-append "subvol=" subvol
                           (if (string=? subvol "@snapshots")
                               ""
                               (string-append "," %btrfs-mount-options))))))

(operating-system
  (inherit %desktop-base-os)
  (host-name "lappie")

  ;; The firmware's SSDT10 would panic acpi_init (see (uraj hardware
  ;; asus)); the patched table must travel in the initrd for the kernel's
  ;; ACPI table override to pick it up.
  (initrd (asus-adolbook-air14-acpi-hack
           (operating-system-initrd %desktop-base-os)))

  ;; Guix does not add the resume argument itself; the initrd resumes
  ;; from a device given as path, UUID, or bare label.
  (kernel-arguments
   (append %default-kernel-arguments
           (list "resume=swap"
                 ;; zswap: compress pages in RAM before they hit the
                 ;; swap device; falls back to the default compressor
                 ;; if the kernel lacks zstd support.
                 "zswap.enabled=1"
                 "zswap.compressor=zstd"
                 "zswap.max_pool_percent=20")
           %asus-adolbook-air14-kernel-cmdlines))

  (bootloader
   (bootloader-configuration
    (bootloader grub-efi-bootloader)
    (targets (list "/boot/efi"))))

  (file-systems
   (cons* (file-system
           (device (file-system-label "EFI"))
           (mount-point "/boot/efi")
           (type "vfat"))
          (btrfs-subvolume "/" "@root")
          (btrfs-subvolume "/home" "@home")
          (btrfs-subvolume "/var" "@var")
          (btrfs-subvolume "/gnu/store" "@gnu")
          (btrfs-subvolume "/data" "@data")
          (btrfs-subvolume "/snapshots" "@snapshots")
          %base-file-systems))

  (swap-devices
   (list (swap-space
          (target (file-system-label "swap"))
          (discard? #t))))

  ;; Naming (services ...) replaces the list inherited from
  ;; %desktop-base-os, so its services are appended back explicitly.
  (services
   (append (operating-system-user-services %desktop-base-os)
           (list ; %asus-adolbook-air14-panel-replay-service
                 ))))
