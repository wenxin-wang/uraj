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
;;;   sgdisk -n 2:0:+32G -t 2:8200 -c 2:swap   /dev/nvme0n1   # >= RAM for hibernation
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
;;;   install -d -m 1777 /mnt/tmp
;;;
;;; On the first boot, log in as wenxin through greetd with an empty password,
;;; then run `passwd' (no sudo) to set a real one.  Until then sudo refuses the
;;; empty password; wheel membership grants permission, not NOPASSWD access.
;;;
;;; Build the matching live installer (maak sets TO_ISO in the Guix process):
;;;   maak -f env/guix/os/maak.scm build-iso

(use-modules (gnu)
             (gnu bootloader)
             (gnu bootloader grub)
             (nongnu system linux-initrd)
             (srfi srfi-1)
             (guix gexp)
             (sops secrets)
             (uraj services strongswan)
             (uraj utils file path)
             (uraj hardware asus)
             (uraj system base)
             (uraj system desktop)
             (uraj system initrd)
             (uraj system iso)
             (uraj system secrets)
             (uraj system storage))

;; The administrator, who also owns the embedded niri Home.
(define %main-user
  (main-user-account "wenxin" #:comment "Wenxin Wang"))

(define %desktop-os
  (desktop-base-os %main-user
                   (local-file (guix-env-path "os/keys/wenxin-ssh.pub"))))

(define %vpn-connections
  (list
   (cons "fwd2home"
         (sops-secret
          (key '("strongswan" "fwd2home"))
          (file (local-file (project-path "secrets/hosts/lappie/strongswan.yaml")))
          (user "root")
          (group "root")
          (permissions #o400)))))

(define lappie-os
  (operating-system
  (inherit %desktop-os)
  (host-name "lappie")

  ;; The firmware's SSDT10 would panic acpi_init (see (uraj hardware
  ;; asus)); the patched table must travel in the initrd for the kernel's
  ;; ACPI table override to pick it up.
  (initrd (asus-adolbook-air14-acpi-hack
           (lambda (file-systems . rest)
             (apply microcode-initrd file-systems
                    #:initrd zstd-zswap-initrd rest))))

  ;; Guix does not add the resume argument itself; the initrd resumes
  ;; from a device given as path, UUID, or bare label.
  (kernel-arguments
   (append %default-kernel-arguments
           (list "resume=swap"
                 ;; zstd is a module in this kernel.  Select it in the
                 ;; initrd after loading the module; early zswap
                 ;; initialization uses the built-in default compressor.
                 "zswap.enabled=1"
                 "zswap.max_pool_percent=20")
           %asus-adolbook-air14-kernel-cmdlines))

  (bootloader
   (bootloader-configuration
    (bootloader grub-efi-bootloader)
    (targets (list "/boot/efi"))))

  (file-systems (btrfs-root-file-systems "lappie"))
  (swap-devices %nvme-swap-devices)

  ;; Naming (services ...) replaces the list inherited from
  ;; %desktop-os, so its services are appended back explicitly.
  (services
   (append (operating-system-user-services %desktop-os)
           (if (getenv "TO_ISO") '()
               (append (host-sops-services (map cdr %vpn-connections))
                       (strongswan-services %vpn-connections)))
           (list ; %asus-adolbook-air14-panel-replay-service
                 )))))

;; `maak build-iso' sets TO_ISO for its Guix subprocess.  Keeping the switch
;; here means this remains the single source of truth for both the installed
;; system and its hardware-matched live image.
(if (getenv "TO_ISO")
    (to-iso lappie-os)
    lappie-os)
