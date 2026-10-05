;;; guix time-machine -C env/guix/channels-lock.scm -- repl -L src/guix test/guix/uraj/services/guix-mirrors.scm
(use-modules (gnu services) (gnu services base)
             (guix gexp) (srfi srfi-1) (srfi srfi-64)
             (uraj system base))
(test-begin "guix-mirrors-service")
(define services
  (base-services
   (list (service guix-service-type
                  (guix-configuration
                   (environment '("EXTRA=retained" "GUIX=/old/helper")))))))
(define config
  (service-value
   (find (lambda (s) (eq? (service-kind s) guix-service-type)) services)))
(test-equal "replace helper while retaining daemon environment"
  '("GUIX=/etc/guix-daemon-command" "EXTRA=retained")
  (guix-configuration-environment config))
(define etc
  (service-value
   (find (lambda (s) (eq? (service-type-name (service-kind s))
                         'guix-crate-mirrors)) services)))
(test-assert "helper installed as a managed etc file"
  (program-file? (cadr (assoc "guix-daemon-command" etc))))
(test-assert "do not collide with Guix's mutable /etc/guix directory"
  (every (lambda (entry)
           (not (string-contains (car entry) "/")))
         etc))
(define failures (test-runner-fail-count (test-runner-current)))
(test-end "guix-mirrors-service")
(exit (if (zero? failures) 0 1))
