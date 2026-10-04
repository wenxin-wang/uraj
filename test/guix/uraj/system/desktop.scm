;; Run with the pinned channels and -L src/guix -L src/guile.
(use-modules (gnu) (gnu services) (gnu services base)
             (gnu home) (gnu home services) (gnu home services shepherd)
             (gnu home services admin) (gnu services admin)
             (gnu services desktop) (gnu system pam) (guix gexp)
             (gnu system accounts)
             ((guix utils) #:select (with-environment-variables))
             (srfi srfi-1) (srfi srfi-13) (srfi srfi-64)
             (uraj system desktop)
             (uraj common context)
             (uraj packages elogind))

(test-begin "desktop-session-lifecycle")
(define target-user
  (user-account (name "target") (group "users")
                (home-directory "/srv/target")))
(with-environment-variables '(("XDG_STATE_HOME" "/tmp/foreign-state"))
  (parameterize ((%main-user target-user) (%for-foreign-home #f))
    (test-equal "system context ignores the build user's environment"
      "/srv/target/.local/state" (home-state-directory))
    (parameterize ((%for-foreign-home #t))
      (test-equal "foreign context honors XDG even with a main user"
        "/tmp/foreign-state" (home-state-directory))
      (with-environment-variables '(("XDG_STATE_HOME" #f))
        (test-equal "foreign context can use an explicit main user"
          "/srv/target/.local/state" (home-state-directory))))
    (test-equal "nested context restores system selection"
      "/srv/target/.local/state" (home-state-directory)))
  (parameterize ((%main-user #f) (%for-foreign-home #t))
    (test-equal "foreign context supports the current user"
      "/tmp/foreign-state" (home-state-directory))
    (with-environment-variables '(("XDG_STATE_HOME" ""))
      (test-equal "empty XDG falls back to the current user's home"
        (string-append (getenv "HOME") "/.local/state")
        (home-state-directory))))
  (parameterize ((%main-user #f) (%for-foreign-home #f))
    (test-error "system context requires a target account" #t
      (home-state-directory))))
(define os (load (string-append (getcwd) "/env/guix/os/lappie.scm")))
(define config
  (service-value
   (fold-services (operating-system-services os)
                  #:target-type pam-root-service-type)))
(define transform
  (apply compose identity
         ((@@ (gnu system pam) pam-configuration-transformers) config)))
(define pams
  (map transform ((@@ (gnu system pam) pam-configuration-services) config)))
(define (module-name entry)
  (let ((module (pam-entry-module entry)))
    (if (file-append? module)
        (string-concatenate (file-append-suffix module))
        module)))

;; Fold the complete graph so elogind's later PAM extension participates.
(for-each
 (lambda (name)
   (let ((pam (find (lambda (p) (string=? name (pam-service-name p))) pams)))
     (test-assert (string-append name " exists") pam)
     (test-assert (string-append name " retains pam_elogind")
       (any (lambda (entry) (string-contains (module-name entry) "pam_elogind.so"))
            (pam-service-session pam)))
     (test-assert (string-append name " has no competing pam_mount")
       (not (any (lambda (entry) (string-contains (module-name entry) "pam_mount.so"))
                 (append (pam-service-auth pam) (pam-service-session pam)))))))
 '("greetd" "login" "su"))
(test-assert "elogind is retained"
  (find (lambda (s) (eq? (service-kind s) elogind-service-type))
        (operating-system-services os)))
(test-assert "desktop uses the orderly Shepherd kexec helper"
  (eq? elogind-with-shepherd-kexec
       ((@@ (gnu services desktop) elogind-configuration-elogind)
        (service-value
         (fold-services (operating-system-services os)
                        #:target-type elogind-service-type)))))

(define home-services
  (home-shepherd-configuration-services
   (service-value
    (fold-services (home-environment-services desktop-home-environment)
                   #:target-type home-shepherd-service-type))))
(define rotation-services
  (filter (lambda (s) (memq 'log-rotation (shepherd-service-provision s)))
          home-services))
(test-equal "Home has one rotation service for native and external logs"
  1 (length rotation-services))
(test-assert "niri remains outside Shepherd process management"
  (not (any (lambda (s) (memq 'niri (shepherd-service-provision s)))
            home-services)))
(define home-log-rotation
  (service-value
   (fold-services (home-environment-services desktop-home-environment)
                  #:target-type home-log-rotation-service-type)))
(define home-variables
  (service-value
   (fold-services (home-environment-services desktop-home-environment)
                  #:target-type home-environment-variables-service-type)))
(test-equal "native Home rotation uses the target user's log path"
  '("/home/wenxin/.local/state/shepherd/niri.log")
  (log-rotation-configuration-external-log-files home-log-rotation))
(test-equal "session writer and native rotation share the log path"
  (car (log-rotation-configuration-external-log-files home-log-rotation))
  (assoc-ref home-variables "NIRI_SESSION_LOG_FILE"))

(define failures (test-runner-fail-count (test-runner-current)))
(test-end "desktop-session-lifecycle")
(exit (if (zero? failures) 0 1))
