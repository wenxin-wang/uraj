;;; Run: guix repl -L src/guix test/guix/deploy-target.scm
(use-modules (gnu home)
             (gnu services)
             (gnu system)
             (gnu system file-systems)
             (gnu bootloader)
             (gnu bootloader grub)
             (srfi srfi-64)
             (uraj system home)
             (uraj system deploy-target))

(define (os-with-homes homes)
  (operating-system
   (host-name "deploy-test")
   (timezone "Etc/UTC")
   (locale "en_US.utf8")
   (bootloader (bootloader-configuration
                (bootloader grub-bootloader)
                (targets '("/dev/test"))))
   (file-systems (cons (file-system
                        (device "/dev/test")
                        (mount-point "/")
                        (type "ext4"))
                      %base-file-systems))
   (services
    (list (service guix-home-with-environment-service-type homes)))))

(define runner (test-runner-simple))
(test-runner-current runner)
(test-begin "deploy-target")
(unsetenv "TO_ISO")
(unsetenv "OS_DEPLOY_TARGET")
(let* ((home (home-environment))
       (os (os-with-homes `(("wenxin" ,home)))))
  (test-eq "default preserves OS" os (deploy-target os))
  (setenv "OS_DEPLOY_TARGET" "system")
  (test-eq "explicit system preserves OS" os (deploy-target os))
  (setenv "OS_DEPLOY_TARGET" "home")
  (test-eq "Home target returns the actual embedded object"
    home (deploy-target os))
  (test-eq "activation dependencies are not mistaken for Homes"
    home
    (deploy-target
     (os-with-homes
      (list (list "wenxin" home)
            (home-activation-dependency "wenxin" '(test-ready))))))
  (test-error "missing Home refused" #t
    (deploy-target (os-with-homes '())))
  (test-error "ambiguous Home refused" #t
    (deploy-target
     (os-with-homes `(("wenxin" ,(home-environment))
                      ("other" ,(home-environment))))))
  (setenv "TO_ISO" "1")
  (test-error "ISO Home refused" #t (deploy-target os))
  (unsetenv "TO_ISO")
  (setenv "OS_DEPLOY_TARGET" "typo")
  (test-error "unknown target refused" #t (deploy-target os)))
(test-end "deploy-target")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
