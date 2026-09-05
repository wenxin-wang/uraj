(use-modules (gnu)
             (gnu system nss))

(use-service-modules networking)

(operating-system
  (host-name "uraj-vm")
  (timezone "Asia/Shanghai")
  (locale "en_US.utf8")
  (name-service-switch %mdns-host-lookup-nss)

  (bootloader
   (bootloader-configuration
    (bootloader grub-bootloader)
    (targets '("/dev/vda"))))

  (file-systems
   (cons (file-system
          (device (file-system-label "root"))
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

  (packages %base-packages)

  (services
   (cons (service dhcpcd-service-type)
         %base-services)))
