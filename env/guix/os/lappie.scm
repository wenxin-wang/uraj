;;; lappie.scm -- Guix System configuration for the development laptop.
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
;;;   sgdisk -n 2:0:+32G -t 2:8200 -c 2:swap   /dev/nvme0n1   ; >= RAM
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
;;; The Home environment is embedded via guix-home-service-type: one
;;; "guix system reconfigure" builds and activates both system and home
;;; in a single generation, and "guix system roll-back" reverts both
;;; together -- no separate "guix home reconfigure" step.  The session
;;; commands below start login shells that source the Guix Home
;;; environment.

(use-modules (gnu)
             (gnu bootloader)
             (gnu bootloader grub)
             (gnu home)
             (gnu packages linux)          ;btrfs-progs, linux-pam
             (gnu services)
             (gnu services base)
             (gnu services guix)
             (gnu system nss)
             (gnu system privilege)
             (nongnu packages linux)
             (nongnu system linux-initrd)
             (rosenthal services base)
             (rosenthal services desktop)
             (srfi srfi-1)
             (uraj home config niri)
             (uraj home services noctalia))

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

(define lappie-home-environment
  (home-environment
   (services (niri-desktop-home-services))))

(operating-system
  (host-name "lappie")
  (timezone "Asia/Shanghai")
  (locale "en_US.utf8")
  (name-service-switch %mdns-host-lookup-nss)

  (kernel linux)
  (initrd microcode-initrd)
  (firmware (list linux-firmware))

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
                 "zswap.max_pool_percent=20")))

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

  (users
   (cons (user-account
          (name "uraj")
          (comment "Uraj")
          (group "users")
          (supplementary-groups '("wheel" "netdev" "audio" "video")))
         %base-user-accounts))

  (packages
   (cons* btrfs-progs       ;subvolume and snapshot management
          %base-packages))

  ;; noctalia's screen locker verifies passwords in-process against the
  ;; system PAM stack; pam_unix offloads to unix_chkpwd, which Guix
  ;; builds to live at /run/privileged/bin/unix_chkpwd.  It is not part
  ;; of %default-privileged-programs, so add the setuid copy.
  (privileged-programs
   (cons (privileged-program
          (program (file-append linux-pam "/sbin/unix_chkpwd"))
          (setuid? #t))
         %default-privileged-programs))

  (services
   (cons* ;; The Home environment lives in the same generation as the
          ;; system; its activation runs as 'uraj' on boot and on
          ;; reconfigure, populating ~/.guix-home.
          (service guix-home-service-type
                   (list (list "uraj" lappie-home-environment)))

          ;; VT1: login through tuigreet, then start the niri session;
          ;; VT2-6: plain shell logins (agreety), like the
          ;; %rosenthal-desktop-services/tuigreet layout.
          (service greetd-service-type
            (greetd-configuration
             (greeter-supplementary-groups '("video" "input"))
             (terminals
              (map (lambda (vt)
                     (greetd-terminal-configuration
                      (terminal-vt (number->string vt))
                      (terminal-switch (eqv? 1 vt))
                      ;; Both session commands below start login shells
                      ;; (bash -l via niri-greetd-user-session, $SHELL
                      ;; -l for the console VTs), so greetd's own
                      ;; profile sourcing would just double-source
                      ;; /etc/profile and ~/.profile.
                      (source-profile? #f)
                      (default-session-command
                       (if (eqv? 1 vt)
                           (greetd-tuigreet-session
                            (args (list "--cmd" (niri-greetd-user-session)
                                        "--time" "--user-menu" "--asterisks"
                                        "--remember" "--remember-session"
                                        "--power-shutdown" "loginctl poweroff"
                                        "--power-reboot" "loginctl reboot")))
                           (greetd-agreety-session
                            (command
                             (greetd-user-session
                              (command #~(getenv "SHELL")))))))))
                   (iota 6 1)))))

          ;; NetworkManager, wpa-supplicant, elogind, dbus, polkit, etc.
          ;; all come from %rosenthal-desktop-services/base (which builds
          ;; on %desktop-services).

          (modify-services %rosenthal-desktop-services/base
            (delete mingetty-service-type)))))
