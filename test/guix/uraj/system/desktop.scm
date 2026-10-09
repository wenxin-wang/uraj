;; Run with the pinned channels and -L src/guix -L src/guile.
(use-modules (gnu) (gnu services) (gnu services base)
             (gnu home) (gnu home services) (gnu home services shepherd)
             (gnu home services admin) (gnu services admin)
             (gnu services desktop) (gnu system pam) (guix gexp)
             (gnu system accounts)
             ((guix utils) #:select (with-environment-variables))
             (srfi srfi-1) (srfi srfi-13) (srfi srfi-64)
             (uraj system desktop)
             (uraj home niri)
             (uraj services paseo)
             (uraj common context)
             (uraj packages elogind)
             (uraj packages window-managers)
             ((rosenthal packages wm) #:select (noctalia)))

(test-begin "desktop-session-lifecycle")
(define target-user
  (user-account (name "target") (group "users")
                (home-directory "/srv/target")))
(with-environment-variables '(("XDG_STATE_HOME" "/tmp/foreign-state"))
  (test-equal "system target ignores the build user's environment"
    "/srv/target/.local/state"
    (home-target-state-directory (guix-system-home-target target-user)))
  (test-assert "system target records nothing about the build machine"
    (let ((target (guix-system-home-target target-user)))
      (and (not (home-target-foreign? target))
           (not (home-target-systemd? target))
           (null? (home-target-os-release target)))))
  (test-equal "foreign target honors XDG"
    "/tmp/foreign-state"
    (home-target-state-directory (foreign-home-target)))
  (with-environment-variables '(("XDG_STATE_HOME" ""))
    (test-equal "empty XDG falls back to the current user's home"
      (string-append (getenv "HOME") "/.local/state")
      (home-target-state-directory (foreign-home-target))))
  (parameterize ((%home-target (guix-system-home-target target-user)))
    (test-equal "the bound target selects the state directory"
      "/srv/target/.local/state" (home-state-directory)))
  (test-error "Home construction requires a bound target" #t
    (home-state-directory)))
(define (fake-foreign-target os-release systemd?)
  (home-target (foreign? #t) (state-directory "/tmp/state")
               (os-release os-release) (systemd? systemd?)))
(test-assert "unknown foreign hosts use plain noctalia"
  (eq? noctalia
       (noctalia-for-host
        (fake-foreign-target '(("ID" . "ubuntu") ("VERSION_ID" . "20.04")) #t))))
(test-assert "Guix System never selects the host PAM closure"
  (eq? noctalia
       (noctalia-for-host
        (home-target (foreign? #f) (state-directory "/tmp/state")
                     (os-release '(("ID" . "ubuntu")
                                   ("VERSION_ID" . "24.04")))))))
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

(define (keyring-entry? entry)
  (string-contains (module-name entry) "pam_gnome_keyring.so"))
(define greetd-pam
  (find (lambda (pam) (string=? "greetd" (pam-service-name pam))) pams))
(define passwd-pam
  (find (lambda (pam) (string=? "passwd" (pam-service-name pam))) pams))
(test-equal "greetd captures the login password exactly once"
  1 (count keyring-entry? (pam-service-auth greetd-pam)))
(test-assert "keyring failure cannot reject a valid greetd login"
  (every (lambda (entry) (string=? "optional" (pam-entry-control entry)))
         (filter keyring-entry?
                 (append (pam-service-auth greetd-pam)
                         (pam-service-session greetd-pam)))))
(test-equal "greetd starts the password daemon exactly once"
  '(("auto_start"))
  (map pam-entry-arguments
       (filter keyring-entry? (pam-service-session greetd-pam))))
(test-equal "passwd synchronizes the login keyring password"
  1 (count keyring-entry? (pam-service-password passwd-pam)))
(test-assert "su does not unlock or start the desktop keyring"
  (let ((pam (find (lambda (pam) (string=? "su" (pam-service-name pam))) pams)))
    (not (any keyring-entry?
              (append (pam-service-auth pam) (pam-service-session pam))))))
(test-assert "elogind is retained"
  (find (lambda (s) (eq? (service-kind s) elogind-service-type))
        (operating-system-services os)))
(test-assert "desktop uses the orderly Shepherd kexec helper"
  (eq? elogind-with-shepherd-kexec
       ((@@ (gnu services desktop) elogind-configuration-elogind)
        (service-value
         (fold-services (operating-system-services os)
                        #:target-type elogind-service-type)))))

(define home (desktop-home-environment target-user))
(define home-services
  (home-shepherd-configuration-services
   (service-value
    (fold-services (home-environment-services home)
                   #:target-type home-shepherd-service-type))))
(define rotation-services
  (filter (lambda (s) (memq 'log-rotation (shepherd-service-provision s)))
          home-services))
(test-equal "native Home initializes the PAM keyring once"
  1 (count (lambda (s) (memq 'gnome-keyring-secrets
                             (shepherd-service-provision s)))
           home-services))
(test-equal "Home has one rotation service for native and external logs"
  1 (length rotation-services))
(test-assert "niri remains outside Shepherd process management"
  (not (any (lambda (s) (memq 'niri (shepherd-service-provision s)))
            home-services)))
(define home-log-rotation
  (service-value
   (fold-services (home-environment-services home)
                  #:target-type home-log-rotation-service-type)))
(define home-variables
  (service-value
   (fold-services (home-environment-services home)
                  #:target-type home-environment-variables-service-type)))
(test-equal "native Home rotation uses the target user's log path"
  '("/srv/target/.local/state/shepherd/niri.log")
  (log-rotation-configuration-external-log-files home-log-rotation))
(test-equal "session writer and native rotation share the log path"
  (car (log-rotation-configuration-external-log-files home-log-rotation))
  (assoc-ref home-variables "NIRI_SESSION_LOG_FILE"))

(define (lookup services name)
  (find (lambda (s) (memq name (shepherd-service-provision s))) services))
(test-assert "lappie has no system Paseo instance"
  (not (any (lambda (s) (eq? (service-kind s) paseo-service-type))
            (operating-system-user-services os))))
(test-equal "desktop broker waits for keyring initialization"
  '(gnome-keyring-secrets)
  (shepherd-service-requirement (lookup home-services 'paseo-broker)))
(test-equal "desktop daemon waits for broker"
  '(paseo-broker)
  (shepherd-service-requirement (lookup home-services 'paseo)))
(for-each
 (lambda (name)
   (test-assert (format #f "~a forces the configured desktop askpass" name)
     (string-contains
      (object->string (gexp->approximate-sexp
                       (shepherd-service-start (lookup home-services name))))
      "SSH_ASKPASS_REQUIRE=force")))
 '(paseo paseo-broker))
(define boot-os
  (desktop-base-os target-user (plain-file "test.pub" "") #:paseo-at-boot? #t))
(test-equal "boot desktop has one system Paseo service"
  1 (count (lambda (s) (eq? (service-kind s) paseo-service-type))
           (operating-system-user-services boot-os)))
(define boot-home-services
  (home-shepherd-configuration-services
   (service-value
    (fold-services
     (home-environment-services
      (desktop-home-environment target-user #:paseo-at-boot? #t))
     #:target-type home-shepherd-service-type))))
(test-assert "boot desktop Home never starts a second daemon or broker"
  (and (not (lookup boot-home-services 'paseo))
       (not (lookup boot-home-services 'paseo-broker))))
(define foreign-services
  (parameterize ((%home-target (fake-foreign-target '() #t)))
    (home-shepherd-configuration-services
     (service-value
      (fold-services
       (home-environment-services
        (home-environment (services (niri-desktop-home-services))))
       #:target-type home-shepherd-service-type)))))
(test-equal "foreign broker uses the existing session, not Guix keyring"
  '(dbus graphical-session)
  (shepherd-service-requirement (lookup foreign-services 'paseo-broker)))
(test-assert "foreign Home starts Paseo and leaves keyring to the host"
  (and (lookup foreign-services 'paseo)
       (not (lookup foreign-services 'gnome-keyring-secrets))))

(define failures (test-runner-fail-count (test-runner-current)))
(test-end "desktop-session-lifecycle")
(exit (if (zero? failures) 0 1))
