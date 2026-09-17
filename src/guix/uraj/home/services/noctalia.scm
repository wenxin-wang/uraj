(define-module (uraj home services noctalia)
  #:use-module (gnu home services)
  #:use-module (gnu home services shepherd)
  #:use-module (gnu services)
  #:use-module (gnu services configuration)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:use-module (ice-9 rdelim)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:use-module ((rosenthal home services desktop) #:prefix rosenthal:)
  #:autoload (rosenthal packages wm) (noctalia)
  #:export (home-noctalia-configuration
            home-noctalia-service-type
            home-niri-noctalia-services))

;;; Like the Rosenthal channel's home-noctalia-service-type, but with
;;; support for extra environment variables (e.g. to LD_PRELOAD the
;;; host's PAM stack into noctalia's screen locker).  It inherits the
;;; upstream service type and replaces its Shepherd extension; drop this
;;; module if upstream ever gains an 'environment-variables' field.

(define-configuration/no-serialization home-noctalia-configuration
  (noctalia
   (file-like noctalia)
   "File-like object to provide @command{/bin/noctalia}.")
  (environment-variables
   (list-of-strings '())
   "Environment variables to pass to noctalia, as a list of
@code{NAME=VALUE} strings."))

(define (home-noctalia-shepherd-service config)
  (match-record config <home-noctalia-configuration>
      (noctalia environment-variables)
    (list (shepherd-service
            (documentation "Start noctalia.")
            (provision '(noctalia))
            (requirement '(dbus graphical-session))
            (modules '((shepherd support)))
            (start
             #~(lambda args
                 ((make-forkexec-constructor
                   (list #$(file-append noctalia "/bin/noctalia"))
                   #:log-file (in-vicinity %user-log-dir "noctalia.log")
                   ;; Inherit graphical session environment plus extras.
                   #:environment-variables
                   (append (list #$@environment-variables) (environ)))
                  args)))
            (stop #~(make-kill-destructor))))))

(define home-noctalia-service-type
  (service-type
    (inherit rosenthal:home-noctalia-service-type)
    (extensions
     (list (service-extension home-profile-service-type
                              (compose list home-noctalia-configuration-noctalia))
           (service-extension home-shepherd-service-type
                              home-noctalia-shepherd-service)
           (service-extension rosenthal:home-graphical-session-service-type
                              (const 'wayland))))
    ;; The inherited default value is an instance of the upstream
    ;; configuration record type; replace it with ours.
    (default-value (home-noctalia-configuration))))

;; Guix's libpam cannot parse Ubuntu's "@include" PAM files, and Guix's
;; loader cannot reach multiarch libraries, so noctalia's screen locker
;; preloads Ubuntu's libpam and its modules' dependency closure (the
;; 'ldd' closure of the modules reachable from /etc/pam.d/login).  No
;; libc is preloaded; the host's /sbin/unix_chkpwd still verifies the
;; password against /etc/shadow.  The closure differs per release, so
;; pick it by the host's /etc/os-release.

(define (ubuntu-pam-preload libs)
  (string-join (map (lambda (lib)
                      (string-append "/usr/lib/x86_64-linux-gnu/" lib))
                    libs)
               ":"))

(define %ubuntu-pam-preload-22.04
  (ubuntu-pam-preload
   '("libpam.so.0"
     "libaudit.so.1"
     "libcap-ng.so.0"
     "libcap.so.2"
     "libcom_err.so.2"
     "libcrack.so.2"
     "libcrypt.so.1"
     "libecryptfs.so.1"
     "libgssapi_krb5.so.2"
     "libk5crypto.so.3"
     "libkeyutils.so.1"
     "libkrb5.so.3"
     "libkrb5support.so.0"
     "libnsl.so.2"
     "libnspr4.so"
     "libnss3.so"
     "libnssutil3.so"
     "libpam_misc.so.0"
     "libpcre2-8.so.0"
     "libplc4.so"
     "libplds4.so"
     "libpwquality.so.1"
     "libselinux.so.1"
     "libtirpc.so.3")))

(define %ubuntu-pam-preload-24.04
  ;; 24.04's login chain no longer pulls in krb5/nsl/tirpc.
  (ubuntu-pam-preload
   '("libpam.so.0"
     "libaudit.so.1"
     "libcap-ng.so.0"
     "libcap.so.2"
     "libcrack.so.2"
     "libcrypt.so.1"
     "libecryptfs.so.1"
     "libkeyutils.so.1"
     "libnspr4.so"
     "libnss3.so"
     "libnssutil3.so"
     "libpam_misc.so.0"
     "libpcre2-8.so.0"
     "libplc4.so"
     "libplds4.so"
     "libpwquality.so.1"
     "libselinux.so.1")))

(define (%os-release-field name)
  "Return the value of field NAME from /etc/os-release, or #f."
  (and (file-exists? "/etc/os-release")
       (call-with-input-file "/etc/os-release"
         (lambda (port)
           (let loop ((line (read-line port)))
             (cond
              ((eof-object? line) #f)
              ((string-prefix? (string-append name "=") line)
               (let ((value (substring line (+ (string-length name) 1))))
                 ;; Strip quotes, e.g. VERSION_ID="24.04".
                 (if (and (> (string-length value) 1)
                          (char=? #\" (string-ref value 0))
                          (char=? #\" (string-ref value (1- (string-length value)))))
                     (substring value 1 (1- (string-length value)))
                     value)))
              (else (loop (read-line port)))))))))

(define (ubuntu-pam-preload-for-version version)
  (cond ((string=? "22.04" version) %ubuntu-pam-preload-22.04)
        ((string=? "24.04" version) %ubuntu-pam-preload-24.04)
        (else #f)))

(define (host-ubuntu-pam-preload)
  "Return the LD_PRELOAD string for the host's Ubuntu PAM stack, or #f
if the host is not Ubuntu 22.04/24.04."
  (and (string=? "ubuntu" (or (%os-release-field "ID") ""))
       (ubuntu-pam-preload-for-version (%os-release-field "VERSION_ID"))))

(define (host-pam-preload-variables)
  "Return the noctalia environment variables that LD_PRELOAD the host's
PAM stack for the screen locker, or '() if the host is unsupported."
  (let ((preload (host-ubuntu-pam-preload)))
    (if (and preload
             (file-exists? "/usr/lib/x86_64-linux-gnu/libpam.so.0"))
        (list (string-append "LD_PRELOAD=" preload))
        '())))

;; The session is managed by the host display manager (GDM on Ubuntu).
;; GDM runs /usr/local/bin/niri-session (host-side wrapper, see below),
;; which sources the Guix Home environment and execs:
;;   niri --session
;; niri then spawns the user Shepherd (spawn-at-startup "shepherd"),
;; which starts noctalia and the other graphical services inside the
;; graphical session.
;;
;; Host-side wrapper (/usr/local/bin/niri-session):
;;   #!/bin/sh
;;   # setup-environment needs HOME_ENVIRONMENT set first (as ~/.profile
;;   # does); without it PATH never gains ~/.guix-home/profile/bin and
;;   # "niri" is not found under GDM's minimal environment.
;;   HOME_ENVIRONMENT="$HOME/.guix-home"
;;   [ -f "$HOME_ENVIRONMENT/setup-environment" ] && \
;;       . "$HOME_ENVIRONMENT/setup-environment"
;;   unset HOME_ENVIRONMENT
;;   if [ -n "$DBUS_SESSION_BUS_ADDRESS" ]; then
;;       niri --session
;;   else
;;       dbus-run-session -- niri --session
;;   fi
;;   # niri exited: logind leaves processes behind (Ubuntu default
;;   # KillUserProcesses=no), so tear the session Shepherd down
;;   # explicitly. This stops the session services (noctalia, fcitx5)
;;   # and frees the Shepherd socket for the next login. Note: niri must
;;   # NOT be exec'd here, otherwise this cleanup never runs.
;;   herd stop root 2>/dev/null || true

(define (home-niri-noctalia-services)
  "Return the list of Home services that run noctalia under a niri
session managed by the host display manager: a session Shepherd (started
by niri, not at login), a stub @code{dbus} service (the session bus is
provided by the host system) and noctalia itself, with the host's PAM
stack preloaded for its screen locker on supported Ubuntu hosts."
  (list
   (service home-shepherd-service-type
            (home-shepherd-configuration
             (auto-start? #f)
             (daemonize? #f)))

   ;; The session bus is provided by the host system (systemd/logind),
   ;; hence the stub instead of home-dbus-service-type.
   (simple-service 'dbus home-shepherd-service-type
                   (list (shepherd-service
                          (provision '(dbus))
                          (start #~(const #t))
                          (stop #~(const #f)))))

   (service home-noctalia-service-type
            (home-noctalia-configuration
             (environment-variables (host-pam-preload-variables))))))
