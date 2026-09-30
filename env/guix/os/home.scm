;; This "home-environment" file can be passed to 'guix home reconfigure'
;; to reproduce the content of your profile.  This is "symbolic": it only
;; specifies package names.  To reproduce the exact same profile, you also
;; need to capture the channels being used, as returned by "guix describe".
;; See the "Replicating Guix" section in the manual.

(use-modules (gnu home)
             (gnu home services)
             (gnu services)
             (uraj hardware nvidia)
             (uraj home niri)
             (uraj packages local-resources))

(define base-home
  (home-environment
   ;; This config is evaluated on the machine it configures, so both
   ;; noctalia (plain vs. the host-PAM-patched variant) and the portal
   ;; flavour default to what this host needs -- no Ubuntu-specific bits
   ;; here, they follow /etc/os-release.
   (services
    (append
     (niri-desktop-home-services)
     ;; Managed hosts additionally provision the corporate PKI into
     ;; /usr/local/share/ca-certificates, which Guix-side programs
     ;; ignore by default: the package merges it into the profile's
     ;; certificate bundle so that Guix programs (git and GIT_SSL_CAINFO
     ;; in particular) trust corporate services too, and the activation
     ;; service imports the same certificates into the NSS databases of
     ;; the Firefox profiles (Firefox reads no other trust store).
     (if (local-ca-certificates-available?)
         (list (simple-service 'local-ca-certs
                               home-profile-service-type
                               (list local-ca-certs))
               (firefox-local-ca-certs-service))
         '())))))

;; The proprietary NVIDIA userspace must match the host's kernel module,
;; so only start grafting when the host actually has the driver loaded
;; *and* its version is pinned in (uraj hardware nvidia).
(if (nvidia-host?)
    (home-transformation-nvidia base-home)
    base-home)
