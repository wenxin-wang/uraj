;;; Run with the locked Guix channels and -L src/guix -L src/guile.
;;; Use the SSH agent for the key already authorized on hypie.
(use-modules (gnu machine)
             (gnu machine ssh)
             (uraj utils file path))

(when (getenv "TO_ISO")
  (error "Unset TO_ISO before deploying an installed system"))

(list
 (machine
  (operating-system
   (primitive-load (project-path "env/guix/os/hypie.scm")))
  (environment managed-host-environment-type)
  (configuration
   (machine-ssh-configuration
    (host-name "hypie.home.labbies.wenxinwang.me")
    (system "x86_64-linux")
    (user "guix-deploy")
    (port 23333)
    (host-key "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINg2CClgdB3vnphGkysV23GduApUS/m+PPqzu0NZdyiU")
    (build-locally? #t)
    ;; The initial deployment coordinates on hypie itself, using its own
    ;; daemon/store.  A different coordinator must first be trusted by hypie.
    (authorize? #f)))))
