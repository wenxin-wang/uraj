(define-module (uraj home basic-dev)
  #:use-module (gnu home)
  #:use-module (gnu home services)
  #:use-module (gnu home services gnupg)
  #:use-module (gnu packages)
  #:use-module (gnu packages gnupg)
  #:use-module (gnu services)
  #:use-module (guix gexp)
  #:use-module (uraj common basic-services)
  #:use-module (uraj utils file path)
  #:export (basic-dev-home-services))

(define (basic-dev-packages)
  (specifications->packages
   '(;; OpenPGP smart cards (YubiKey/CanoKey), commit signing and the
     ;; gpg-agent SSH agent.  Card access goes through the host's pcscd
     ;; (Ubuntu: 'apt install pcscd'; Guix System: pcscd-service-type),
     ;; so the stock package suffices.  Keep a terminal pinentry here so
     ;; basic-dev also works on machines without a desktop environment.
     "gnupg"
     "pinentry-tty"
     ;; Git
     "github-cli"
     ;; Python
     "uv"
     ;; Google C/C++ and Python style, also used by commit checks.
     "python"
     "clang"
     "cpplint"
     "ruff"
     ;; Containers.  Guix System hosts get subids, cgroup delegation and
     ;; /etc/containers from rootless-podman-service-type (see (uraj
     ;; system desktop)); podman-compose drives the podman CLI directly,
     ;; so no API socket service is needed for compose projects.
     "podman"
     "podman-compose"
     ;; Deployment
     "ansible")))

;;; The gpg-agent runs under the session Shepherd (see the service below),
;;; so on foreign distros the host must not start its own: systemd user
;;; units such as Ubuntu's gpg-agent.socket bind the same sockets in
;;; $XDG_RUNTIME_DIR/gnupg and would hold them before the session starts.
;;; Masking (a /dev/null symlink in ~/.config/systemd/user, undone with
;;; 'systemctl --user unmask') keeps the sockets for the Guix agent.  The
;;; guard makes this a no-op on hosts without systemd user gpg units, such
;;; as Guix System.
(define %host-gpg-agent-systemd-units
  '("gpg-agent.service"
    "gpg-agent.socket"
    "gpg-agent-extra.socket"
    "gpg-agent-browser.socket"
    "gpg-agent-ssh.socket"))

(define (mask-host-gpg-agent-systemd-units)
  (simple-service
   'mask-host-gpg-agent-systemd-units
   home-activation-service-type
   (with-imported-modules '((guix build utils))
     #~(begin
         (use-modules (guix build utils))
         (when (or (file-exists? "/usr/lib/systemd/user/gpg-agent.socket")
                   (file-exists? "/lib/systemd/user/gpg-agent.socket"))
           (let ((unit-dir (string-append (getenv "HOME")
                                          "/.config/systemd/user")))
             (mkdir-p unit-dir)
             (for-each
              (lambda (unit)
                (let* ((mask (string-append unit-dir "/" unit))
                       ;; Guile's lstat throws on ENOENT, unlike stat.
                       (st (catch 'system-error
                             (lambda () (lstat mask))
                             (lambda args #f))))
                  ;; Leave anything that already exists alone -- a mask
                  ;; from a previous activation or a user-written unit.
                  (unless st
                    (symlink "/dev/null" mask))))
              '#$%host-gpg-agent-systemd-units)))))))

(define home-gpg-agent/keep-ssh-auth-sock-service-type
  ;; With ssh-support?, the upstream service exports SSH_AUTH_SOCK
  ;; unconditionally in setup-environment, clobbering the socket that
  ;; `ssh -A` forwards into remote login shells.  Only default to the
  ;; gpg-agent socket when the session has no agent yet.
  (service-type
   (inherit home-gpg-agent-service-type)
   (extensions
    (map (lambda (extension)
           (if (eq? (service-extension-target extension)
                    home-environment-variables-service-type)
               (service-extension
                home-environment-variables-service-type
                (lambda (config)
                  (if (home-gpg-agent-configuration-ssh-support? config)
                      '(("SSH_AUTH_SOCK"
                         . "${SSH_AUTH_SOCK:-$XDG_RUNTIME_DIR/gnupg/S.gpg-agent.ssh}"))
                      '())))
               extension))
         (service-type-extensions home-gpg-agent-service-type)))))

(define (basic-dev-gpg-agent-service)
  ;; Generates ~/.gnupg/gpg-agent.conf from this configuration; all
  ;; machines run Guix Home or Guix System, so this is the only source
  ;; for that file.
  (service
   home-gpg-agent/keep-ssh-auth-sock-service-type
   (home-gpg-agent-configuration
    (gnupg gnupg)
    ;; The dotfiles script, copied into the store: it picks a graphical
    ;; pinentry when the requesting client has a display and falls back to
    ;; pinentry-tty (also in this profile) otherwise.
    (pinentry-program
     ;; Recursive store import preserves the script's executable bit.
     (local-file (project-path "env/dotfiles/dev/bin/.local/bin/pinentry-auto")
                 #:recursive? #t))
    (ssh-support? #t)
    (default-cache-ttl 3600)
    ;; Keep the SSH key passphrase cached for a day of idleness and a week
    ;; overall, so pinentry does not pop up every hour or two.
    (default-cache-ttl-ssh 86400)
    (max-cache-ttl-ssh 604800)
    ;; ssh-support? only affects the supervised instance; on-demand
    ;; launches in console/SSH sessions read the config file instead, so
    ;; keep the ssh socket there too.
    (extra-content "enable-ssh-support\n"))))

(define (basic-dev-home-services)
  (append
   (list
    (simple-service 'basic-dev-packages
                    home-profile-service-type
                    (basic-dev-packages))
    (basic-dev-gpg-agent-service)
    (mask-host-gpg-agent-systemd-units))
   (my-dotfiles-services
    (list (project-path "env/dotfiles/dev")))))
