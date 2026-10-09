;;; hypie.scm -- desktop with an NVIDIA GTX 1080 and an existing ZFS pool.
;;;
;;; Same desktop as lappie (see (uraj system desktop)); adds NVIDIA's
;;; proprietary driver over the whole system, the "data" ZFS pool, a
;;; driver for its USB Wi-Fi adapter, and the fwd2home VPN, connected at
;;; boot.
;;;
;;; Observed 2026-10-07 on the previous Arch Linux installation:
;;;   CPU   i5-7500, HD Graphics 630 (00:02.0, boot VGA; the monitor is on
;;;         its HDMI port, so the desktop runs on the Intel GPU)
;;;   dGPU  GTX 1080 (01:00.0, GP104, Pascal); Arch bound it to vfio-pci.
;;;         Pascal needs the 580 branch with the CLOSED kernel module: the
;;;         open module requires Turing, and 595+ dropped Pascal.
;;;   Wi-Fi USB MediaTek MT7921U (0e8d:7961); its driver is built here,
;;;         see mt7921u-linux-module in (uraj packages wireless).
;;;   Eth   RTL8168h (r8169, rtl_nic firmware from linux-firmware)
;;;   Fans  ITE IT8613E Super I/O at ISA 0xa30, driven by the out-of-tree
;;;         it87; Arch ran fancontrol, whose curves are kept below.
;;;   Arch boots in legacy BIOS mode; every disk is MBR, none has an ESP.
;;;   Guix boots in UEFI mode instead, from a new ESP on the system disk.
;;;   Keep CSM (legacy boot) enabled in the firmware alongside UEFI, or
;;;   Arch on the Kingbank disk stops booting.
;;;
;;; Disks, by identity (sdX names are NOT stable: the live USB stick
;;; itself may well become sda):
;;;   ata-KINGBANK_KP330_I49015E005856   111.8G  Arch root (xfs).
;;;       NEVER partition, format, mount read-write or install GRUB here;
;;;       it may hold data with no backup.
;;;   ata-Samsung_SSD_860_EVO_250GB_S3YLNX0KA07780E  232.9G  old Windows,
;;;       to be erased: this becomes the Guix system disk.
;;;   nvme-Netac_NVMe_SSD_1TB_TE202310101T12121646  ZFS pool "data"
;;;       (created by OpenZFS 2.4.0; Guix has 2.4.4):
;;;         data -> /data, data/wenxin -> /data/wenxin (owned 1000:1000)
;;;       The pool takes /data, so the Btrfs @data subvolume of the other
;;;       machines is left out here.
;;;
;;; Arch's home directory lives in the pool, so Arch cannot export it
;;; before shutting down, and Guix (whose hostid differs) then refuses the
;;; automatic import.  Make sure Arch is really shut down -- not suspended
;;; or hibernated -- and force the import once by hand, in the live system
;;; without mounting anything:
;;;   zpool import -f -N data
;;; and again on the first boot of the installed system if zfs-import
;;; failed there too, then start what waits for it:
;;;   sudo zpool import -f data
;;;   sudo herd start zfs-data-ready
;;; Booting back into Arch will need the same forced import there.
;;;
;;; Build the live installer (TO_ISO is set by maak):
;;;   maak -f env/guix/os/maak.scm build-iso env/guix/os/hypie.scm
;;; Boot it in UEFI mode (the "UEFI: <stick>" boot menu entry):
;;; installing GRUB registers a boot entry through EFI variables, which a
;;; legacy-booted live system does not have.  Check before installing:
;;;   test -d /sys/firmware/efi && echo UEFI
;;; The live system imports the pool without mounting it:
;;;   herd status zfs-import
;;;   zpool status -P
;;;
;;; The live system can connect the fwd2home VPN with lappie's SOPS secret,
;;; which an administrator OpenPGP card can decrypt (pcscd is running).
;;; Its SOPS service fails at boot; unlock the card in root's GnuPG home,
;;; which the service uses, by decrypting once interactively, then retry
;;; the service and start the VPN:
;;;   passwd                                   # sudo needs a password
;;;   sudo -i
;;;   export GPG_TTY=$(tty)
;;;   gpg --card-status                        # card plugged in: key stubs
;;;   sops -d /etc/strongswan-sops.yaml >/dev/null   # asks the PIN
;;;   herd start sops-secrets
;;;   herd start vpn-fwd2home
;;;
;;; DESTRUCTIVE: erases the Samsung SSD only.  Use by-id paths throughout,
;;; and check the identity of the disk before every destructive command:
;;;   system_disk=/dev/disk/by-id/ata-Samsung_SSD_860_EVO_250GB_S3YLNX0KA07780E
;;;   keep_disk=/dev/disk/by-id/ata-KINGBANK_KP330_I49015E005856
;;;   lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,LABEL,MOUNTPOINTS
;;;   test "$(readlink -f "$system_disk")" != "$(readlink -f "$keep_disk")" &&
;;;     lsblk -no MODEL "$system_disk" | grep -q 'Samsung SSD 860' &&
;;;     echo OK
;;; Same layout as lappie and storie, except for the @data subvolume.
;;; No other disk has an "EFI", "swap" or "hypie" label (checked
;;; 2026-10-07), so the labels below are unambiguous.
;;;   wipefs -a "$system_disk"-part*
;;;   sgdisk --zap-all "$system_disk"
;;;   sgdisk -n 1:0:+1G  -t 1:ef00 -c 1:EFI   "$system_disk"
;;;   sgdisk -n 2:0:+16G -t 2:8200 -c 2:swap  "$system_disk"
;;;   sgdisk -n 3:0:0    -t 3:8300 -c 3:hypie "$system_disk"
;;;   partprobe "$system_disk"
;;;   udevadm settle
;;;   mkfs.fat -F32 -n EFI "${system_disk}-part1"
;;;   mkswap -L swap "${system_disk}-part2"
;;;   mkfs.btrfs -L hypie "${system_disk}-part3"
;;;   mount "${system_disk}-part3" /mnt
;;;   for s in root home var gnu snapshots; do
;;;     btrfs subvolume create /mnt/@$s
;;;   done
;;;   umount /mnt
;;;
;;; Mount ALL subvolumes before init so /gnu/store lands in @gnu:
;;;   mount -o subvol=@root,compress=zstd "${system_disk}-part3" /mnt
;;;   mkdir -p /mnt/boot/efi /mnt/home /mnt/var /mnt/gnu/store \
;;;            /mnt/snapshots
;;;   mount -o subvol=@home,compress=zstd "${system_disk}-part3" /mnt/home
;;;   mount -o subvol=@var,compress=zstd "${system_disk}-part3" /mnt/var
;;;   mount -o subvol=@gnu,compress=zstd "${system_disk}-part3" /mnt/gnu/store
;;;   mount -o subvol=@snapshots "${system_disk}-part3" /mnt/snapshots
;;;   mount "${system_disk}-part1" /mnt/boot/efi
;;;   swapon "${system_disk}-part2"
;;;   install -d -m 1777 /mnt/tmp
;;;   # The desktop live image's rootless Podman makes / rshared, and
;;;   # cow-store's MS_MOVE of its overlay onto /gnu/store fails with
;;;   # EINVAL under a shared parent mount.
;;;   mount --make-rprivate /
;;;   herd start cow-store /mnt
;;;
;;; The installed system connects fwd2home at boot with its own SOPS
;;; secret, encrypted to the age identity derived from its SSH host key.
;;; Create that host key now (activation keeps an existing one), so the
;;; secret exists before `system init' and the VPN works on first boot:
;;;   install -d -m 755 /mnt/etc/ssh
;;;   ssh-keygen -q -t ed25519 -N '' -C root@hypie \
;;;     -f /mnt/etc/ssh/ssh_host_ed25519_key
;;;   ssh-to-age < /mnt/etc/ssh/ssh_host_ed25519_key.pub \
;;;     > secrets/keys/hosts/hypie.age.pub
;;; Add that recipient to .sops.yaml as &hypie-age, with a rule for
;;; ^secrets/hosts/hypie/[^/]+\.yaml$ (pgp: *admin, age: *hypie-age) like
;;; lappie's.  Then, with the card unlocked as for the live VPN above,
;;; copy lappie's connection secret without writing it in plain text:
;;;   mkdir -p secrets/hosts/hypie
;;;   sops -d secrets/hosts/lappie/strongswan.yaml |
;;;     sops -e --filename-override secrets/hosts/hypie/strongswan.yaml \
;;;       --input-type yaml --output-type yaml /dev/stdin \
;;;       > secrets/hosts/hypie/strongswan.yaml
;;; Commit these three files afterwards.
;;;
;;; From the repository, with its module paths available (TO_ISO unset):
;;;   guix time-machine -C env/guix/channels-lock.scm -- \
;;;     system init -L src/guix -L src/guile env/guix/os/hypie.scm /mnt
;;; GRUB is written only into the ESP mounted at /mnt/boot/efi, plus a
;;; "Guix" UEFI boot entry; no disk's MBR is touched.  Then export the pool
;;; if the live system imported it:
;;;   zpool export data
;;; The firmware should now list "Guix" first; Arch remains reachable as
;;; the Kingbank disk's legacy entry in the boot menu.
;;;
;;; First login: wenxin through greetd with an empty password, then passwd.

(use-modules (gnu)
             (gnu bootloader)
             (gnu bootloader grub)
             (gnu packages file-systems)
             (gnu packages gnupg)
             ((gnu packages linux) #:select (lm-sensors))
             (gnu packages password-utils)
             (gnu services linux)
             ;; (gnu services containers)
             ;; (gnu services docker)
             (gnu services shepherd)
             (guix gexp)
             (guix packages)
             (guix utils)
             (nongnu packages linux)
             (nongnu packages nvidia)
             (nongnu system linux-initrd)
             (nonguix transformations)
             (rosenthal services file-systems)
             (sops secrets)
             (sops services sops)
             (srfi srfi-1)
             (uraj packages hwmon)
             (uraj packages wireless)
             (uraj services strongswan)
             ;; (uraj services redroid)
             (uraj system base)
             (uraj system desktop)
             (uraj system initrd)
             (uraj system iso)
             (uraj system secrets)
             (uraj system storage)
             (uraj system zfs)
             (uraj utils file path))

(define %main-user
  (main-user-account "wenxin" #:comment "Wenxin Wang"))

(define %desktop-os
  (desktop-base-os %main-user
                   (local-file (guix-env-path "os/keys/wenxin-ssh.pub"))
                   #:paseo-at-boot? #t))

;; Match the module builds to the inherited operating-system kernel.
(define zfs-linux
  (package
    (inherit zfs)
    (name (string-append "zfs-for-linux-"
                         (version-major+minor (package-version linux))))
    (arguments
     (substitute-keyword-arguments (package-arguments zfs)
       ((#:linux _) (operating-system-kernel %desktop-os))))))

;; Arch's /etc/fancontrol, written by pwmconfig on 2024-02-06 and used
;; since: both channels follow the CPU package temperature.  pwm2/fan2
;; runs from 42 C to full speed at 80 C; pwm3/fan3 only from 75 C, full
;; at 90 C.  Below MINTEMP both get PWM 0 (MINSTOP=0), and MINSTART=150
;; kicks a stopped fan.
;; Identified by running one channel at a time on 2026-10-07:
;;   pwm2/fan2  two quieter case fans on the right; never stop, ~990 RPM
;;              at PWM 0, ~2070 at 255.
;;   pwm3/fan3  three loudest case fans on the left; stop at PWM 0,
;;              ~4245 RPM at 255.
;;   pwm5       CPU cooler, without a tachometer; its speed does not
;;              visibly follow PWM, so it is left to the firmware.
;; Its hwmon numbers came from Arch's probe order, which Guix (with
;; NVIDIA's and the NVMe's sensors) does not share: @IT87@ and @CORETEMP@
;; are resolved from DEVPATH when the service starts.  fancontrol itself
;; still rejects a DEVPATH/DEVNAME mismatch.
(define %hypie-fancontrol-template
  (string-append
   "INTERVAL=10\n"
   "DEVPATH=@IT87@=devices/platform/it87.2608 "
   "@CORETEMP@=devices/platform/coretemp.0\n"
   "DEVNAME=@IT87@=it8613 @CORETEMP@=coretemp\n"
   "FCTEMPS=@IT87@/pwm3=@CORETEMP@/temp1_input "
   "@IT87@/pwm2=@CORETEMP@/temp1_input\n"
   "FCFANS=@IT87@/pwm3=@IT87@/fan3_input @IT87@/pwm2=@IT87@/fan2_input\n"
   "MINTEMP=@IT87@/pwm3=75 @IT87@/pwm2=42\n"
   "MAXTEMP=@IT87@/pwm3=90 @IT87@/pwm2=80\n"
   "MINSTART=@IT87@/pwm3=150 @IT87@/pwm2=150\n"
   "MINSTOP=@IT87@/pwm3=0 @IT87@/pwm2=0\n"))

(define %hypie-fancontrol
  (program-file
   "hypie-fancontrol"
   #~(begin
       (use-modules (ice-9 ftw) (ice-9 regex) (srfi srfi-1))
       (define (hwmon device)
         (or (find (lambda (entry)
                     (false-if-exception
                      (string=? (canonicalize-path
                                 (string-append "/sys/class/hwmon/" entry
                                                "/device"))
                                (string-append "/sys/" device))))
                   (or (scandir "/sys/class/hwmon"
                                (lambda (entry)
                                  (string-prefix? "hwmon" entry)))
                       '()))
             (error "No hwmon for" device)))
       (define config "/run/fancontrol.conf")
       (call-with-output-file config
         (lambda (port)
           (display (regexp-substitute/global
                     #f "@IT87@"
                     (regexp-substitute/global
                      #f "@CORETEMP@" #$%hypie-fancontrol-template
                      'pre (hwmon "devices/platform/coretemp.0") 'post)
                     'pre (hwmon "devices/platform/it87.2608") 'post)
                    port)))
       (execl #$(file-append lm-sensors "/sbin/fancontrol")
              "fancontrol" config))))

(define %hypie-fan-services
  (list (simple-service 'hypie-hwmon kernel-module-loader-service-type
                        '("it87" "coretemp"))
        (simple-service 'hypie-fancontrol shepherd-root-service-type
          (list
           (shepherd-service
             (provision '(fancontrol))
             (requirement '(user-processes kernel-module-loader))
             (documentation "Control the case fans by CPU temperature.")
             (start #~(make-forkexec-constructor
                       (list #$%hypie-fancontrol)
                       #:log-file "/var/log/fancontrol.log"))
             (stop #~(make-kill-destructor)))))))

(define (hypie-os zfs-services)
  ;; Graft nvda over mesa in every package and service, the embedded Home
  ;; included, and load the closed 580 module.  nvda still carries mesa's
  ;; own drivers, so the Intel GPU keeps working for the desktop.
  ((nonguix-transformation-nvidia #:driver nvda-580)
   (operating-system
     (inherit %desktop-os)
     (host-name "hypie")

     (initrd (lambda (file-systems . rest)
               (apply microcode-initrd file-systems
                      #:initrd zstd-zswap-initrd rest)))

     (kernel-arguments
      (append %default-kernel-arguments
              ;; zstd is a module in this kernel.  Select it in the initrd
              ;; after loading the module; early zswap initialization uses
              ;; the built-in default compressor.
              (list "zswap.enabled=1"
                    "zswap.max_pool_percent=20")))

     (kernel-loadable-modules
      (cons* (mt7921u-linux-module (operating-system-kernel %desktop-os))
             (it87-linux-module (operating-system-kernel %desktop-os))
             (operating-system-kernel-loadable-modules %desktop-os)))

     (bootloader
      (bootloader-configuration
       (bootloader grub-efi-bootloader)
       (targets (list "/boot/efi"))))

     ;; /data belongs to the ZFS pool.
     (file-systems
      (remove (lambda (file-system)
                (string=? (file-system-mount-point file-system) "/data"))
              (btrfs-root-file-systems "hypie")))
     (swap-devices %nvme-swap-devices)

     (services
      (append zfs-services
              %hypie-fan-services
              (trust-substitute-servers
               (operating-system-user-services %desktop-os)
               (list (local-file
                      (guix-env-path "os/keys/storie-signing-key.pub"))
                     (local-file
                      (guix-env-path "os/keys/lappie-signing-key.pub")))
               #:urls '("http://172.31.0.5:8080")))))))

(define %vpn-connections
  (list
   (cons "fwd2home"
         (sops-secret
          (key '("strongswan" "fwd2home"))
          (file (local-file (project-path "secrets/hosts/hypie/strongswan.yaml")))
          (user "root")
          (group "root")
          (permissions #o400)))))

(define hypie-installed-os
  (hypie-os
   (append
    (list (service zfs-data-service-type
            (zfs-configuration (zfs zfs-linux)))
          (zfs-data-ready-service
           '(("data" . "/data")
             ("data/wenxin" . "/data/wenxin"))))
    ;; Disabled pending a separate redroid deployment.  Uncomment the imports
    ;; above along with this block to enable it on the installed system only.
    ;; (list (service containerd-service-type)
    ;;       (service docker-service-type %redroid-docker-configuration)
    ;;       (service oci-service-type (oci-configuration (runtime 'docker)))
    ;;       (service redroid-network-service-type)
    ;;       (service redroid-service-type
    ;;                (redroid-configuration (auto-start? #f))))
    (host-sops-services (map cdr %vpn-connections))
    (strongswan-services %vpn-connections #:at-boot '("fwd2home")))))

;; The live system has no host key that SOPS secrets are encrypted to,
;; but lappie's are also encrypted to the administrator's OpenPGP cards.
;; Run the standard SOPS service on root's GnuPG home instead of a host
;; identity: it fails at boot, and decrypts once a card is unlocked there.
(define %live-gnupg-home "/root/.gnupg")

(define %live-vpn-sops-file
  (local-file (project-path "secrets/hosts/lappie/strongswan.yaml")))

(define %live-vpn-secret
  (sops-secret
   (key '("strongswan" "fwd2home"))
   (file %live-vpn-sops-file)
   (user "root")
   (group "root")
   (permissions #o400)))

(define %live-vpn-services
  (list
   ;; Shepherd's sops has no terminal to ask for the PIN, so it can only
   ;; use a card already unlocked by an interactive root gpg, through the
   ;; same agent: give root's agent a terminal pinentry and the public key.
   (simple-service 'live-root-gnupg activation-service-type
     #~(let ((home #$%live-gnupg-home))
         (unless (file-exists? home)
           (mkdir home))
         (chmod home #o700)
         (call-with-output-file (string-append home "/gpg-agent.conf")
           (lambda (port)
             (format port "pinentry-program ~a~%"
                     #$(file-append pinentry-tty "/bin/pinentry-tty"))))
         (system* #$(file-append gnupg "/bin/gpg") "--homedir" home
                  "--batch" "--import"
                  #$(local-file (project-path "secrets/keys/admin.asc")))))
   ;; For the interactive decryption that unlocks the card, and for
   ;; encrypting the installed system's secret to its new host key.
   (simple-service 'live-sops-tools profile-service-type
                   (list sops ssh-to-age))
   (simple-service 'live-vpn-sops-file etc-service-type
                   `(("strongswan-sops.yaml" ,%live-vpn-sops-file)))
   (service sops-secrets-service-type
     (sops-service-configuration
       (gnupg-home %live-gnupg-home)
       (secrets (list %live-vpn-secret))))))

;; `maak build-iso' sets TO_ISO for its Guix subprocess.  The live system
;; imports the pool to check it, but mounts nothing.
(if (getenv "TO_ISO")
    (to-iso
     (hypie-os
      (cons (service zfs-data-service-type
              (zfs-configuration
                (zfs zfs-linux)
                (auto-mount? #f)))
            (append %live-vpn-services
                    (strongswan-services
                     `(("fwd2home" . ,%live-vpn-secret)))))))
    hypie-installed-os)
