(define-module (uraj home services noctalia)
  #:use-module (gnu home services)
  #:use-module (gnu home services shepherd)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (ice-9 rdelim)
  #:use-module (srfi srfi-13)
  #:use-module ((rosenthal home services desktop) #:prefix rosenthal:)
  #:autoload (rosenthal packages wm) (noctalia)
  #:use-module (uraj packages noctalia)
  #:export (home-niri-noctalia-services))

;;; Noctalia's screen locker verifies passwords with the host's PAM
;;; stack, in-process.  Guix's libpam silently skips Ubuntu's "@include"
;;; directives (so pam_authenticate can never succeed) and its loader
;;; cannot reach the multiarch libraries the host's PAM modules need, so
;;; on Ubuntu hosts noctalia runs as a patched variant whose DT_NEEDED
;;; list prepends the host PAM closure -- see (uraj packages noctalia).
;;; The closure differs per release, so pick it by the host's
;;; /etc/os-release.

(define (ubuntu-pam-libs libs)
  (map (lambda (lib)
         (string-append "/usr/lib/x86_64-linux-gnu/" lib))
       libs))

(define %ubuntu-pam-libs-22.04
  (ubuntu-pam-libs
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

(define %ubuntu-pam-libs-24.04
  ;; 24.04's login chain no longer pulls in krb5/nsl/tirpc.
  (ubuntu-pam-libs
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

(define (ubuntu-pam-libs-for-version version)
  (cond ((string=? "22.04" version) %ubuntu-pam-libs-22.04)
        ((string=? "24.04" version) %ubuntu-pam-libs-24.04)
        (else #f)))

(define (host-ubuntu-pam-libs)
  "Return the host PAM closure as a list of absolute library file names,
or #f if the host is not Ubuntu 22.04/24.04."
  (and (string=? "ubuntu" (or (%os-release-field "ID") ""))
       (ubuntu-pam-libs-for-version (%os-release-field "VERSION_ID"))))

(define (noctalia-for-host)
  (let ((libs (host-ubuntu-pam-libs)))
    (if (and libs
             (file-exists? "/usr/lib/x86_64-linux-gnu/libpam.so.0"))
        (noctalia-with-host-pam noctalia libs)
        noctalia)))

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
;;   # setup-environment requires HOME_ENVIRONMENT to be set first (as
;;   # ~/.profile does).  Self-contained on purpose: GDM imports the
;;   # systemd user-manager environment only on hosts that have a
;;   # user-environment-generator; on hosts without one this source is
;;   # the only thing that puts the Guix Home profile on PATH.
;;   HOME_ENVIRONMENT="$HOME/.guix-home"
;;   [ -f "$HOME_ENVIRONMENT/setup-environment" ] && \
;;       . "$HOME_ENVIRONMENT/setup-environment"
;;   unset HOME_ENVIRONMENT
;;   # Ubuntu 22.04's user session runs PulseAudio (audio) and a
;;   # video-only PipeWire; the session Shepherd starts its own
;;   # PipeWire + WirePlumber + pipewire-pulse instead.  Stop the host
;;   # units (sockets included, so they cannot reactivate) to free the
;;   # pipewire-0 and pulse/native sockets in XDG_RUNTIME_DIR.
;;   systemctl --user stop pipewire.socket pipewire.service \
;;       pipewire-media-session.service pulseaudio.socket pulseaudio.service \
;;       2>/dev/null || true
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
provided by the host system) and noctalia itself, patched with the
host's PAM stack for its screen locker on supported Ubuntu hosts."
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

   (service rosenthal:home-noctalia-service-type
            (rosenthal:home-noctalia-configuration
             (noctalia (noctalia-for-host))))))
