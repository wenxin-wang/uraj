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
  #:use-module (uraj services guix-mirrors)
  #:use-module (uraj services rsyslog)
  #:export (base-os main-user-account user-account-with-groups
            base-openssh-configuration
            %tmp-file-system base-services
            %greetd-console-session base-greetd-configuration))

;;; Same SSH identity and port on desktop and server; root remains locked.
;;; SSH-KEY, a file-like object of public keys, admits the main user and,
;;; restricted to commands, the deployment account.
(define (base-openssh-configuration main-user ssh-key)
  (openssh-configuration
   (port-number 23333)
   (authorized-keys
    (list (list (user-account-name main-user) ssh-key)
          (list "guix-deploy"
                (computed-file
                 "guix-deploy-authorized-keys"
                 #~(begin
                     (use-modules (ice-9 rdelim))
                     (call-with-output-file #$output
                       (lambda (out)
                         (call-with-input-file #$ssh-key
                           (lambda (in)
                             (let loop ((line (read-line in)))
                               (unless (eof-object? line)
                                 (unless (string-null? line)
                                   (format out "restrict ~a~%" line))
                                 (loop (read-line in)))))))))))))))

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

;;; The main user is the machine's administrator and the owner of its
;;; embedded Guix Home.  Machine configurations name it; roles only add
;;; the groups their services need, through user-account-with-groups.
(define* (main-user-account name #:key (comment "")
                            (supplementary-groups '()))
  "Return the account of the main user NAME, a member of 'wheel' and
'log-readers' in addition to SUPPLEMENTARY-GROUPS."
  (user-account
    (name name)
    (comment comment)
    (group "users")
    ;; Initialize only: Guix preserves passwords on reconfigure.  Greetd
    ;; permits first login; sudo still requires a password set with passwd.
    (password "")
    (supplementary-groups
     (append '("wheel" "log-readers") supplementary-groups))))

(define (user-account-with-groups user groups)
  "Return USER additionally in GROUPS."
  (user-account
    (inherit user)
    (supplementary-groups
     (append (user-account-supplementary-groups user) groups))))

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

(define (base-services main-user ssh-key services)
  "Add shared SSH, store publishing, and Guix settings to SERVICES.
MAIN-USER and the deployment account log in with SSH-KEY."
  (cons* (service openssh-service-type
                  (base-openssh-configuration main-user ssh-key))
         (simple-service
          'guix-crate-mirrors etc-service-type
          ;; /etc/guix is a mutable directory maintained by Guix itself.
          ;; etc-service-type installs top-level links, not files into it.
          `(("guix-daemon-command"
             ,(guix-mirror-command
               (guix-configuration-guix
                (service-value
                 (find (lambda (service)
                         (eq? (service-kind service) guix-service-type))
                       services)))))))
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
              (rsyslog-services services)
              (cons (service avahi-service-type) (rsyslog-services services)))
          (guix-service-type config =>
            (guix-configuration
              (inherit config)
              ;; GUIX selects the daemon's helper, independently of clients
              ;; (including time-machine).  Keep package derivations intact.
              (environment
               (cons "GUIX=/etc/guix-daemon-command"
                     (filter (lambda (entry)
                               (not (string-prefix? "GUIX=" entry)))
                             (guix-configuration-environment config))))
              (substitute-urls
               '("https://mirror.sjtu.edu.cn/guix-bordeaux"
                 "https://mirror.sjtu.edu.cn/guix"
                 "https://bordeaux.guix.gnu.org"
                 "https://ci.guix.gnu.org"
                 "https://substitutes.nonguix.org"))
              (authorized-keys
               (cons %nonguix-signing-key
                     (guix-configuration-authorized-keys config))))))))

(define (base-os main-user ssh-key)
  "Return the headless foundation administered by MAIN-USER, a
<user-account> (see main-user-account), who logs in with SSH-KEY, a
file-like object of public keys."
  (operating-system
    (host-name "base")
    (bootloader (bootloader-configuration (bootloader grub-bootloader)))
    (file-systems %base-file-systems)
    (timezone "Asia/Shanghai")
    (locale "en_US.utf8")
    (kernel linux)
    (initrd microcode-initrd)
    (firmware (list linux-firmware))
    (users (cons* main-user %deploy-user %base-user-accounts))
    (sudoers-file %deploy-sudoers)
    (packages (cons btrfs-progs %base-packages))
    (services (base-services main-user ssh-key %base-services))))
