;;; storie.scm -- headless NAS; NVMe Btrfs system + existing ZFS data pools.
;;;
;;; Observed 2026-09-28, BEFORE migration:
;;;   nvme0n1p1: BIOS boot; p2: ESP UUID 4AD3-983B; p3: rpool
;;;   rpool/ROOT/pve-1 is Proxmox /; rpool/data contains containers 100/101.
;;;   sda + sdb: core-data mirror, mounted at /core-data (~941 GiB used)
;;;     archive -> /core-data/archive; backups -> /core-data/backups
;;;   sdc: media-data single disk, mounted at /media-data (~340 GiB used)
;;; Data member identities (do NOT repartition, format, or create pools here):
;;;   core-data: ata-WDC_WD20EFPX-68C4TN0_WD-WX72D636L2YT-part1
;;;              ata-WDC_WD20EFRX-68EUZN0_WD-WCC4M7TX4Y1K-part1
;;;   media-data: ata-WDC_WD20EFRX-68EUZN0_WD-WCC4M7TX4JRX-part1
;;;
;;; Build the headless live installer from the repository environment:
;;;   maak -f env/guix/os/maak.scm build-iso env/guix/os/storie.scm
;;; Equivalent (with src/guix and src/guile on GUILE_LOAD_PATH):
;;;   TO_ISO=1 guix time-machine -C env/guix/channels-lock.scm -- \
;;;     system image -t iso9660 env/guix/os/storie.scm
;;; ISO uses the same ZFS import service as the installed system, but does
;;; NOT mount datasets automatically: the old rpool root must not cover /.
;;; Import failures remain visible without blocking login, DHCP or SSH.
;;; No NFS or storage timers run in the installer.  Inspect import status:
;;;   herd status zfs-import
;;;   zpool status -P
;;;   zpool import                         # list pools still available
;;; If needed, diagnose the failed import; do not blindly add -f.  After
;;; resolving the cause, retry with: herd start zfs-import
;;; To access data after successful import, mount only the needed datasets:
;;;   zfs mount core-data
;;;   zfs mount core-data/archive
;;;   zfs mount core-data/backups
;;;   zfs mount media-data
;;; Do not mount rpool/ROOT/pve-1 over the live root.
;;;
;;; DESTRUCTIVE NVMe replacement, not an in-place conversion:
;;; First back up and verify recovery of containers 100/101, Proxmox config,
;;; and all other required files from rpool, onto storage outside this NVMe.
;;; Stop the containers/NFS users and cleanly export core-data and media-data
;;; from Proxmox before shutting it down.  Preserve numeric UIDs/GIDs in the
;;; data pools: changing the login account does not migrate file ownership.
;;;
;;; Boot the ISO.  Become root after setting wenxin's password with passwd.
;;; Inspect lsblk and zpool status -P; confirm this exact physical SSD:
;;;   system_disk=/dev/disk/by-id/nvme-X15_SSD_512GB_2A148000000000000163
;;;   lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINTS "$system_disk"
;;;   zpool status -P
;;; If the ISO imported rpool (check zpool status),
;;; export it before repartitioning (do not force export a busy pool):
;;;   zpool export rpool
;;; Continue ONLY after backup verification and checking the disk identity.
;;; The following destroys the old rpool, including BOTH containers:
;;;   sgdisk --zap-all "$system_disk"
;;;   sgdisk -n 1:0:+1G  -t 1:ef00 -c 1:EFI    "$system_disk"
;;;   sgdisk -n 2:0:+16G -t 2:8200 -c 2:swap   "$system_disk"
;;;   sgdisk -n 3:0:0    -t 3:8300 -c 3:storie "$system_disk"
;;;   partprobe "$system_disk"
;;;   udevadm settle
;;; Clear stale filesystem/ZFS signatures ONLY on the new NVMe partitions:
;;;   wipefs -a "${system_disk}-part1"
;;;   wipefs -a "${system_disk}-part2"
;;;   wipefs -a "${system_disk}-part3"
;;;   mkfs.fat -F32 -n EFI "${system_disk}-part1"
;;;   mkswap -L swap "${system_disk}-part2"
;;;   mkfs.btrfs -L storie "${system_disk}-part3"
;;;   mount "${system_disk}-part3" /mnt
;;;   for s in root home var gnu data snapshots; do
;;;     btrfs subvolume create /mnt/@$s
;;;   done
;;;   umount /mnt
;;;
;;; Same subvolumes/options as lappie; 32 GiB dedicated NVMe swap.
;;; Mount ALL subvolumes before init so /gnu/store lands in @gnu:
;;;   mount -o subvol=@root,compress=zstd "${system_disk}-part3" /mnt
;;;   mkdir -p /mnt/boot/efi /mnt/home /mnt/var /mnt/gnu/store \
;;;            /mnt/data /mnt/snapshots
;;;   mount -o subvol=@home,compress=zstd "${system_disk}-part3" /mnt/home
;;;   mount -o subvol=@var,compress=zstd "${system_disk}-part3" /mnt/var
;;;   mount -o subvol=@gnu,compress=zstd "${system_disk}-part3" /mnt/gnu/store
;;;   mount -o subvol=@data,compress=zstd "${system_disk}-part3" /mnt/data
;;;   mount -o subvol=@snapshots "${system_disk}-part3" /mnt/snapshots
;;;   mount "${system_disk}-part1" /mnt/boot/efi
;;;   swapon "${system_disk}-part2"
;;;   install -d -m 1777 /mnt/tmp
;;;   herd start cow-store /mnt
;;; From the repository, with its module paths available (TO_ISO unset):
;;;   guix time-machine -C env/guix/channels-lock.scm -- \
;;;     system init env/guix/os/storie.scm /mnt
;;; Before reboot, export data pools imported in the live session:
;;;   zpool export core-data
;;;   zpool export media-data
;;;
;;; Installed ZFS data service adapts Rosenthal's import/mount support,
;;; without making login, DHCP or SSH depend on data pools.  No pool/dataset
;;; recreation or property changes are needed.  If a pool was not cleanly exported, investigate its
;;; ownership instead of adding automatic force-import.  NFS and maintenance
;;; timers wait for zfs-data-ready, which verifies all four dataset mounts.
;;; After repairing a pool failure, retry with:
;;;   herd start zfs-data-ready
;;;   herd start nfs
;;;   herd start zfs-scrub-core-data
;;;   herd start zfs-scrub-media-data
;;;   herd start zfs-snapshot-hourly
;;;   herd start zfs-snapshot-daily
;;; Login and networking remain available during recovery.  Clients must use
;;; the new host's address
;;; (the previous NFS service ran in container 100 at 172.31.255.6).
;;;
;;; Like Testament, snapshot timers use --default-exclude: they protect ONLY
;;; datasets explicitly marked com.sun:auto-snapshot=true.  No existing data
;;; dataset had this property at inspection time.  To opt in after migration:
;;;   zfs set com.sun:auto-snapshot=true core-data/archive
;;;   zfs set com.sun:auto-snapshot=true core-data/backups
;;; Hourly retention: 72; daily: 31.  These are local snapshots, not backups.
;;;
;;; First login: wenxin, empty password on the text console, then passwd.
;;; SSH: port 23333, same authorized key/policy as lappie; root login disabled.

(use-modules (gnu)
             (gnu bootloader)
             (gnu bootloader grub)
             (gnu packages file-systems)
             (gnu packages nfs)
             (gnu packages version-control)
             (gnu services)
             (gnu services nfs)
             (gnu services shepherd)
             (guix gexp)
             (guix packages)
             (guix utils)
             (nongnu packages linux)
             (rosenthal services file-systems)
             (uraj system server)
             (uraj system storage)
             (uraj system iso)
             (uraj system zfs))

;; Match the module build to the inherited operating-system kernel.
(define zfs-linux
  (package
    (inherit zfs)
    (name (string-append "zfs-for-linux-"
                         (version-major+minor (package-version linux))))
    (arguments
     (substitute-keyword-arguments (package-arguments zfs)
       ((#:linux _) (operating-system-kernel %server-base-os))))))

(define zfs-auto-snapshot-linux
  (package
    (inherit zfs-auto-snapshot)
    ;; The snapshot script embeds absolute zfs/zpool paths, so PATH alone
    ;; cannot select the same ZFS build used by the system service.
    (inputs
     (modify-inputs (package-inputs zfs-auto-snapshot)
       (replace "zfs" zfs-linux)))))

(define %data-pools '("core-data" "media-data"))

;; Preserve the exports and client networks read from container 100.
(define %nfs-exports
  (map (lambda (directory)
         (list directory
               "192.168.1.0/24(rw,sync,no_subtree_check,crossmnt)"
               "172.31.128.0/17(rw,sync,no_subtree_check,crossmnt)"
               "fdff:ffff:ffff:fff0::/60(rw,sync,no_subtree_check,crossmnt)"))
       '("/core-data" "/media-data")))

(define (zfs-snapshot-timer name keep label event)
  ;; Shepherd timer running zfs-auto-snapshot over all pools/datasets.
  (shepherd-timer (list name)
    event
    #~(#$(program-file
          (symbol->string name)
          (with-imported-modules '((guix build utils))
            #~(begin
                (use-modules (guix build utils))
                ;; zfs/zpool live in the system profile sbin, which
                ;; zfs-service-type extends with the zfs package.
                (setenv "PATH"
                        "/run/current-system/profile/bin:/run/current-system/profile/sbin")
                (invoke #$(file-append zfs-auto-snapshot-linux "/sbin/zfs-auto-snapshot")
                        "--default-exclude" "--skip-scrub"
                        #$(string-append "--keep=" (number->string keep))
                        #$(string-append "--label=" label)
                        "//")))))
    #:requirement '(user-processes zfs-data-ready)))

(define %storage-timer-services
  (list
   (simple-service 'zfs-scrub shepherd-root-service-type
     (map (lambda (pool)
            (shepherd-timer (list (string->symbol (string-append "zfs-scrub-" pool)))
              #~(calendar-event #:days-of-week '(sunday)
                                #:hours '(0) #:minutes '(0))
              #~(#$(file-append zfs-linux "/sbin/zpool") "scrub" "-w" #$pool)
              #:requirement '(user-processes zfs-data-ready)))
          %data-pools))
   (simple-service 'zfs-snapshot-hourly shepherd-root-service-type
     (list (zfs-snapshot-timer 'zfs-snapshot-hourly 72 "hourly"
                              #~(calendar-event #:minutes '(0)))))
   (simple-service 'zfs-snapshot-daily shepherd-root-service-type
     (list (zfs-snapshot-timer 'zfs-snapshot-daily 31 "daily"
                              #~(calendar-event #:hours '(0) #:minutes '(0)))))))

(define storie-os
  (operating-system
    (inherit %server-base-os)
    (host-name "storie")
    (bootloader
     (bootloader-configuration
       (bootloader grub-efi-bootloader)
       (targets '("/boot/efi"))))
    (file-systems (btrfs-root-file-systems "storie"))
    (swap-devices %nvme-swap-devices)
    (packages
     (cons* git nfs-utils (operating-system-packages %server-base-os)))
    (services
     (append
      (list (service zfs-data-service-type
              (zfs-configuration (zfs zfs-linux)))
            (zfs-data-ready-service
             '(("core-data" . "/core-data")
               ("core-data/archive" . "/core-data/archive")
               ("core-data/backups" . "/core-data/backups")
               ("media-data" . "/media-data")))
            (service nfs-on-zfs-service-type
              (nfs-configuration (exports %nfs-exports))))
      %storage-timer-services
      (operating-system-user-services %server-base-os)))))

(if (getenv "TO_ISO")
    (to-iso
     (operating-system
       (inherit storie-os)
       ;; Exercise pool imports without mounting the old system over the ISO.
       (services
        (cons (service zfs-data-service-type
                (zfs-configuration
                  (zfs zfs-linux)
                  (auto-mount? #f)))
              (operating-system-user-services %server-base-os)))))
    storie-os)
