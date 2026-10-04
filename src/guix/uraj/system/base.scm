;;; Shared, headless foundation for personal systems.
(define-module (uraj system base)
  #:use-module (gnu)
  #:use-module (gnu bootloader)
  #:use-module (gnu bootloader grub)
  #:use-module (gnu packages linux)
  #:use-module (gnu services)
  #:use-module (gnu services avahi)
  #:use-module (gnu services base)
  #:use-module (gnu services ssh)
  #:use-module (guix base32)
  #:use-module (guix download)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (nongnu packages linux)
  #:use-module (nongnu system linux-initrd)
  #:use-module (srfi srfi-1)
  #:export (%base-os %base-user %base-openssh-configuration
            %tmp-file-system base-services
            %greetd-console-session base-greetd-configuration))

(define %admin-ssh-public-key
  "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCaK0O50zlTIaIUeaAmfOXTYpansMf7wjQsZCprTIkp8OhgB7XvDwqzLP9xJ3yzKsej8Am4v02d1RHQgCFi2KDmSTAjBFScRAkb5gDXtchPxc0XH4EFNGT1MqmNubDFNsJdMIUyHiPw5iEjsH+pV9qEuWry+1YVNMefjbKz38XTO3r7Ti+Oxq62HErypslYbHUG2wP2c5mS6n+3Ty+Nq3UG8zqhGgd6iIqrNPYC0u6JLiYe/HD6yd3bGuFDAPwJvgKFeDp9R67ScK7BEY9Z5yv6BPKgwGeJ4UvUASpWNdIszIzR/e5qvYa3uBZPgR/6I4J7X8sk3UGtP6VRe2EgclYb simple\n")

;;; Same SSH identity and port on desktop and server; root remains locked.
(define %base-openssh-configuration
  (openssh-configuration
   (port-number 23333)
   (authorized-keys
    (list (list "wenxin"
                (plain-file "wenxin-authorized-keys" %admin-ssh-public-key))
          (list "guix-deploy"
                (plain-file "guix-deploy-authorized-keys"
                            (string-append "restrict " %admin-ssh-public-key)))))))

;; Deploy needs a shell for SSH commands, but no password or wheel membership.
(define %deploy-user
  (user-account
    (name "guix-deploy")
    (comment "Guix remote deployment")
    (group "users")
    (password "*")
    (home-directory "/var/lib/guix-deploy")))

;; guix deploy invokes these two interpreter entry points, not system
;; reconfigure.  They can evaluate arbitrary root code: this is a command
;; allowlist, NOT a privilege boundary for an untrusted deployment operator.
;; Keep guix resolution in the root-owned system profile.  The Guile store
;; path varies with the coordinator's pinned Guix, hence the anchored regex.
(define %deploy-sudoers
  (plain-file "sudoers"
    (string-append
     (plain-file-content %sudoers-specification)
     "\nDefaults:guix-deploy secure_path=\"/run/current-system/profile/bin:/run/current-system/profile/sbin\"\n"
     "guix-deploy ALL=(root) NOPASSWD: /run/current-system/profile/bin/guix repl -t machine, ^/gnu/store/[0-9a-z]{32}-guile-[^/]+/bin/guile$ --no-auto-compile *\n")))

(define %nonguix-signing-key
  (origin
    (method url-fetch)
    (uri "https://substitutes.nonguix.org/signing-key.pub")
    (sha256
     (base32 "0j66nq1bxvbxf5n8q2py14sjbkn57my0mjwq7k1qm9ddghca7177"))))

(define %tmp-file-system
  (file-system
    (mount-point "/tmp")
    (device "none")
    (type "tmpfs")
    (flags '(no-suid no-dev))
    (options "mode=1777,size=16G")
    (check? #f)
    (create-mount-point? #t)))

(define %base-user
  (user-account
    (name "wenxin")
    (comment "Wenxin Wang")
    (group "users")
    ;; Initialize only: Guix preserves passwords on reconfigure.  Greetd
    ;; permits first login; sudo still requires a password set with passwd.
    (password "")
    (supplementary-groups '("wheel"))))

(define %greetd-console-session
  (greetd-agreety-session
    (command
     (greetd-user-session
       (command #~(getenv "SHELL"))))))

;; SESSION-COMMAND maps a VT number to its default session command.
;; Greetd's record constructor is syntax, so forward extra fields with a
;; macro, retaining its field names and compile-time validation.
(define-syntax-rule (base-greetd-configuration session-command extra-field ...)
  (let ((session-for-vt session-command))
    (greetd-configuration
      ;; Only greetd accepts the initial empty password; sudo is unchanged.
      (allow-empty-passwords? #t)
      (terminals
       (map (lambda (vt)
              (greetd-terminal-configuration
                (terminal-vt (number->string vt))
                (terminal-switch (= vt 1))
                ;; Sessions start login shells, which source profiles.
                (source-profile? #f)
                (default-session-command (session-for-vt vt))))
            (iota 6 1)))
      extra-field ...)))

(define (base-services services)
  "Add shared SSH, store publishing, and Guix settings to SERVICES."
  (cons* (service openssh-service-type %base-openssh-configuration)
         (service guix-publish-service-type
           (guix-publish-configuration
             (host "0.0.0.0")
             (port 8080)
             (advertise? #t)))
         ;; Desktop services already include Avahi; headless systems need it
         ;; too so that live installers can discover their published store.
         (modify-services
          (if (any (lambda (s) (eq? (service-kind s) avahi-service-type))
                   services)
              services
              (cons (service avahi-service-type) services))
          (guix-service-type config =>
            (guix-configuration
              (inherit config)
              (substitute-urls
               '("https://mirror.sjtu.edu.cn/guix-bordeaux"
                 "https://mirror.sjtu.edu.cn/guix"
                 "https://bordeaux.guix.gnu.org"
                 "https://ci.guix.gnu.org"
                 "https://substitutes.nonguix.org"))
              (authorized-keys
               (cons %nonguix-signing-key
                     (guix-configuration-authorized-keys config))))))))

(define %base-os
  (operating-system
    (host-name "base")
    (bootloader (bootloader-configuration (bootloader grub-bootloader)))
    (file-systems %base-file-systems)
    (timezone "Asia/Shanghai")
    (locale "en_US.utf8")
    (kernel linux)
    (initrd microcode-initrd)
    (firmware (list linux-firmware))
    (users (cons* %base-user %deploy-user %base-user-accounts))
    (sudoers-file %deploy-sudoers)
    (packages (cons btrfs-progs %base-packages))
    (services (base-services %base-services))))
