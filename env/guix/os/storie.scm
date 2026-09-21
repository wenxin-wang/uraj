;;; storie.scm -- Guix System configuration for the NAS ("storie").
;;;
;;; Headless server: NFS + ZFS + git-over-SSH.  Unlike lappie.scm there
;;; is no desktop stack; services build on %base-services.
;;;
;;; System disk (ext4 root; file systems are referenced by label, so
;;; the disk name does not matter):
;;;
;;;   sda1  ESP    vfat   /boot/efi   label "EFI"
;;;   sda2  root   ext4   /           label "storie"
;;;
;;;   sgdisk --zap-all /dev/sda
;;;   sgdisk -n 1:0:+1G -t 1:ef00 -c 1:EFI    /dev/sda
;;;   sgdisk -n 2:0:0   -t 2:8300 -c 2:storie /dev/sda
;;;   mkfs.fat -F32 -n EFI /dev/sda1
;;;   mkfs.ext4 -L storie /dev/sda2
;;;
;;; ZFS data pool (adjust the vdev layout and disk names to the actual
;;; hardware before running this):
;;;
;;;   zpool create -o ashift=12 \
;;;                -O acltype=posix -O xattr=sa \
;;;                -O compression=lz4 -O atime=off \
;;;                -O mountpoint=/srv \
;;;                storie mirror /dev/sdb /dev/sdc
;;;   zfs create storie/git      ; -> /srv/git    bare repos, ssh only
;;;   zfs create storie/share    ; -> /srv/share  exported over NFS
;;;
;;; With mountpoint=/srv on the pool, datasets inherit it and land on
;;; /srv/<name>.  The pool and its datasets are mounted at boot by
;;; rosenthal's zfs-service-type (zpool import -a -N, then
;;; zfs mount -a -l), so they are not listed in (file-systems ...).
;;;
;;; The kernel is the nonguix 'linux' (latest stable): same configuration
;;; as the matching linux-libre, but with non-free firmware and drivers
;;; restored, which the NAS NIC may need.  Since guix's 'zfs' package
;;; builds its modules against linux-libre-lts, zfs-linux below rebuilds
;;; it against this kernel (#:linux override) so the module vermagic
;;; matches.  There is no DKMS in guix; the rebuild is its equivalent.
;;;
;;; After first boot, set passwords on the console (passwd as root and
;;; for uraj) and replace the placeholder key in %admin-ssh-keys
;;; before the first reconfigure.

(use-modules (gnu)
             (gnu bootloader)
             (gnu bootloader grub)
             (gnu packages file-systems)      ;zfs, zfs-auto-snapshot
             (gnu packages nfs)               ;nfs-utils
             (gnu packages ssh)               ;openssh-sans-x
             (gnu packages version-control)   ;git
             (gnu services)
             (gnu services base)
             (gnu services networking)
             (gnu services nfs)
             (gnu services shepherd)
             (gnu services ssh)
             (guix gexp)
             (guix packages)                  ;package, package-version
             (guix utils)                     ;substitute-keyword-arguments
             (nongnu packages linux)          ;linux, linux-firmware
             (nongnu system linux-initrd)     ;microcode-initrd
             (rosenthal services file-systems))

(define %zpool-name "storie")

;; Guix's zfs is built against linux-libre-lts; rebuild it against the
;; nonguix kernel so the shipped modules match its vermagic.
(define zfs-linux
  (package
    (inherit zfs)
    (name (string-append "zfs-for-linux-"
                         (version-major+minor (package-version linux))))
    (arguments
     (substitute-keyword-arguments (package-arguments zfs)
       ((#:linux _) linux)))))

;; Keys that may log in as 'uraj' over SSH; file-likes, as
;; openssh-service-type expects.  Fill in before the first deploy.
(define %admin-ssh-keys
  (list (plain-file "uraj.pub"
                    "ssh-ed25519 AAAA...REPLACE-ME\n")))

(define %nfs-exports
  ;; (directory client-options...).  exportfs runs after the ZFS
  ;; datasets are mounted: rpcbind requires user-processes, which
  ;; zfs-service-type makes depend on zfs-mount.
  (list (list "/srv/share" "192.168.1.0/24(rw,sync,no_subtree_check)")))

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
                (invoke #$(file-append zfs-auto-snapshot "/sbin/zfs-auto-snapshot")
                        "--default-exclude" "--skip-scrub"
                        #$(string-append "--keep=" (number->string keep))
                        #$(string-append "--label=" label)
                        "//")))))
    #:requirement '(user-processes)))

(operating-system
  (host-name "storie")
  (timezone "Asia/Shanghai")
  (locale "en_US.utf8")

  ;; Nonguix kernel: same config as the matching linux-libre, with
  ;; non-free firmware/drivers restored.  zfs-linux is rebuilt against
  ;; it so the module vermagic matches.  microcode-initrd, as on
  ;; lappie, prepends the CPU microcode image to the initrd.
  (kernel linux)
  (initrd microcode-initrd)
  (firmware (list linux-firmware))

  (bootloader
   (bootloader-configuration
    (bootloader grub-efi-bootloader)
    (targets (list "/boot/efi"))))

  (file-systems
   (cons* (file-system
           (device (file-system-label "EFI"))
           (mount-point "/boot/efi")
           (type "vfat"))
          (file-system
           (device (file-system-label "storie"))
           (mount-point "/")
           (type "ext4"))
          %base-file-systems))

  (users
   (cons (user-account
          (name "uraj")
          (comment "Uraj")
          (group "users")
          (supplementary-groups '("wheel")))
         %base-user-accounts))

  (packages
   (cons* git
          nfs-utils        ;exportfs & co. for debugging
          ;; zfs and friends land in the profile via zfs-service-type.
          %base-packages))

  (services
   (cons* ;; DHCP on all Ethernet interfaces.  For a NAS a static
          ;; address is preferable (NFS clients depend on it): either
          ;; pin a lease on the router, or replace this with
          ;; (service static-networking-service-type
          ;;   (list (static-networking
          ;;           (addresses (list (network-address
          ;;                              (device "eno1")
          ;;                              (value "192.168.1.2/24"))))
          ;;           (routes (list (network-route
          ;;                            (destination "default")
          ;;                            (gateway "192.168.1.1"))))
          ;;           (name-servers '("192.168.1.1")))))
          (service dhcpcd-service-type)

          ;; ZFS: extends profile/udev with the zfs package, exposes
          ;; the kernel modules, and runs zfs-import/zfs-mount at boot.
          (service zfs-service-type
            (zfs-configuration
             (zfs zfs-linux)))

          (service nfs-service-type
            (nfs-configuration
             (exports %nfs-exports)))

          (service openssh-service-type
            (openssh-configuration
             (openssh openssh-sans-x)))

          (simple-service 'extend-openssh-authorized-keys openssh-service-type
            `(("uraj" ,@%admin-ssh-keys)))

          ;; Weekly scrub, plus automatic hourly/daily snapshots.
          (simple-service 'zfs-scrub shepherd-root-service-type
            (list (shepherd-timer '(zfs-scrub)
                    #~(calendar-event #:days-of-week '(sunday)
                                      #:hours '(0) #:minutes '(0))
                    #~(#$(file-append zfs-linux "/sbin/zpool") "scrub" "-w" #$%zpool-name)
                    #:requirement '(user-processes))))

          (simple-service 'zfs-snapshot-hourly shepherd-root-service-type
            (list (zfs-snapshot-timer 'zfs-snapshot-hourly 72 "hourly"
                                      #~(calendar-event #:minutes '(0)))))

          (simple-service 'zfs-snapshot-daily shepherd-root-service-type
            (list (zfs-snapshot-timer 'zfs-snapshot-daily 31 "daily"
                                      #~(calendar-event #:hours '(0) #:minutes '(0)))))

          %base-services)))
