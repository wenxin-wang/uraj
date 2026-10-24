;;; Run: guix repl -L src/guix test/guix/paseo-trial.scm
(use-modules (gnu home)
             (gnu home services shepherd)
             (gnu services)
             (gnu services shepherd)
             (gnu system)
             (gnu system file-systems)
             (gnu bootloader)
             (gnu bootloader grub)
             (guix gexp)
             (srfi srfi-64)
             (uraj system home)
             (uraj system paseo-trial))

(define (dummy-service name)
  (shepherd-service
   (provision (list name))
   (start #~(const #t))
   (stop #~(const #f))))

(define stack
  (map dummy-service '(paseo paseo-broker)))

(define (test-os system-stack home-stack)
  (operating-system
   (host-name "trial-test")
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
    (list
     (simple-service 'test-stack shepherd-root-service-type system-stack)
     (service guix-home-with-environment-service-type
       `(("wenxin"
          ,(home-environment
            (services
             (list (simple-service 'test-home-stack
                                   home-shepherd-service-type
                                   home-stack)))))))))))

(define runner (test-runner-simple))
(test-runner-current runner)
(test-begin "paseo-trial")
(unsetenv "TO_ISO")
(unsetenv "URAJ_DEPLOY_TARGET")
(let ((os (test-os '() stack)))
  (test-eq "default preserves OS" os (paseo-trial-target os)))
(setenv "URAJ_DEPLOY_TARGET" "paseo")
(test-assert "user stack exports a bundle"
  (file-like? (paseo-trial-target (test-os '() stack))))
(test-assert "system stack exports a bundle"
  (file-like? (paseo-trial-target (test-os stack '()))))
(test-error "duplicate ownership refused" #t
  (paseo-trial-target (test-os stack stack)))
(test-error "missing stack refused" #t
  (paseo-trial-target (test-os '() '())))
(test-error "partial stack refused" #t
  (paseo-trial-target (test-os (list (car stack)) '())))
(test-error "split ownership refused" #t
  (paseo-trial-target (test-os (list (car stack)) (list (cadr stack)))))
(setenv "TO_ISO" "1")
(test-error "ISO trial refused" #t
  (paseo-trial-target (test-os stack '())))
(unsetenv "TO_ISO")
(setenv "URAJ_DEPLOY_TARGET" "home")
(define (os-with-homes homes)
  (operating-system
   (inherit (test-os '() '()))
   (services
    (list (service guix-home-with-environment-service-type homes)))))
(let ((home (home-environment)))
  (test-eq "Home target returns the actual embedded object"
    home
    (paseo-trial-target (os-with-homes `(("wenxin" ,home)))))
  (test-eq "activation dependencies are not mistaken for Homes"
    home
    (paseo-trial-target
     (os-with-homes
      (list (list "wenxin" home)
            (home-activation-dependency "wenxin" '(test-ready)))))))
(test-assert "system-owned Paseo does not prevent Home export"
  (home-environment? (paseo-trial-target (test-os stack '()))))
(test-error "missing Home refused" #t
  (paseo-trial-target (os-with-homes '())))
(test-error "ambiguous Home refused" #t
  (paseo-trial-target
   (os-with-homes `(("wenxin" ,(home-environment))
                    ("other" ,(home-environment))))))
(setenv "TO_ISO" "1")
(test-error "ISO Home refused" #t
  (paseo-trial-target (test-os '() stack)))
(unsetenv "TO_ISO")
(setenv "URAJ_DEPLOY_TARGET" "typo")
(test-error "unknown target refused" #t
  (paseo-trial-target (test-os '() stack)))
(setenv "URAJ_DEPLOY_TARGET" "system")
(let ((os (test-os '() stack)))
  (test-eq "explicit system preserves OS" os (paseo-trial-target os)))
(test-end "paseo-trial")
(exit (if (zero? (test-runner-fail-count runner)) 0 1))
