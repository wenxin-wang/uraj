;;; Run from the repository root with the locked channels and both -L paths.
(use-modules (gnu machine)
             (gnu machine ssh)
             (uraj utils file path))

(when (getenv "TO_ISO")
  (error "Unset TO_ISO before deploying an installed system"))

(define target-os
  (primitive-load (project-path "env/guix/os/storie.scm")))

(list
 (machine
  (operating-system target-os)
  (environment managed-host-environment-type)
  (configuration
   (machine-ssh-configuration
    (host-name "storie.home.labbies.wenxinwang.me")
    (system "x86_64-linux")
    (user "guix-deploy")
    (port 23333)
    (identity (string-append (getenv "HOME") "/.ssh/simple"))
    (host-key "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHDIsqs2WMavtHgNmHXnu9EVXTBML1YXHuApKRiFZVwL")
    (build-locally? #t)
    (authorize? #t)))))
