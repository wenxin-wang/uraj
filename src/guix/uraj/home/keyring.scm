(define-module (uraj home keyring)
  #:use-module (gnu home services)
  #:use-module (gnu home services shepherd)
  #:use-module (gnu home services xdg)
  #:use-module (gnu packages gnome)
  #:use-module (gnu services)
  #:use-module (guix gexp)
  #:use-module (uraj common context)
  #:export (keyring-home-services))

(define %keyring-initialization
  (shepherd-service
   (documentation "Initialize the PAM-unlocked GNOME password service.")
   (provision '(gnome-keyring-secrets))
   (requirement '(dbus graphical-session))
   (one-shot? #t)
   ;; --start joins the daemon that PAM started with --login, before its
   ;; initialization timeout expires.  Without PAM, it starts the same
   ;; secrets-only service and first use prompts for an unlock password.
   (start #~(lambda _
              (zero? (system*
                      #$(file-append gnome-keyring "/bin/gnome-keyring-daemon")
                      "--start" "--components=secrets"))))
   (stop #~(const #f))))

(define (keyring-home-services)
  "Use the host Secret Service on foreign distros, Guix Keyring otherwise.
Neither path enables the GNOME/GCR SSH agent.  Guix System initializes
the secrets component of the daemon unlocked by greetd's PAM stack."
  (append
   (if (home-target-foreign? (current-home-target))
       '()
       (list (simple-service 'gnome-keyring-secrets
                             home-profile-service-type
                             (list gnome-keyring))
             (simple-service 'gnome-keyring-initialization
                             home-shepherd-service-type
                             (list %keyring-initialization))))
   (list
    ;; Older host GNOME Keyring releases provide SSH through XDG autostart.
    ;; Keep secrets/PAM and the host's existing password database intact.
    (simple-service 'disable-gnome-keyring-ssh
                    home-xdg-configuration-files-service-type
                    `(("autostart/gnome-keyring-ssh.desktop"
                       ,(plain-file "gnome-keyring-ssh.desktop"
                                    "[Desktop Entry]\nType=Application\nName=GNOME SSH agent (disabled)\nHidden=true\n"))))
    ;; Newer hosts use separate socket-activated GCR units.  This does not
    ;; mask gnome-keyring-daemon.service/socket: that is our password store.
    (simple-service
     'disable-gcr-ssh-agent
     home-activation-service-type
     (with-imported-modules '((guix build utils))
       #~(begin
           (use-modules (guix build utils))
           (let* ((config-home (getenv "XDG_CONFIG_HOME"))
                  (directory
                   (string-append
                    (if (and config-home (not (string-null? config-home)))
                        config-home
                        (string-append (getenv "HOME") "/.config"))
                    "/systemd/user")))
             (mkdir-p directory)
             (for-each
              (lambda (unit)
                (let* ((path (string-append directory "/" unit))
                       (st (false-if-exception (lstat path))))
                  (cond
                   ((not st) (symlink "/dev/null" path))
                   ((and (eq? 'symlink (stat:type st))
                         (string=? "/dev/null" (readlink path))) #t)
                   (else
                    (error "Cannot mask GCR SSH agent: existing user unit"
                           path)))))
              '("gcr-ssh-agent.socket" "gcr-ssh-agent.service")))))))))
