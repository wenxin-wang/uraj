;; This "home-environment" file can be passed to 'guix home reconfigure'
;; to reproduce the content of your profile.  This is "symbolic": it only
;; specifies package names.  To reproduce the exact same profile, you also
;; need to capture the channels being used, as returned by "guix describe".
;; See the "Replicating Guix" section in the manual.

(use-modules (gnu home)
             (uraj home niri))

(home-environment
 ;; This config is evaluated on the machine it configures, so both
 ;; noctalia (plain vs. the host-PAM-patched variant) and the portal
 ;; flavour default to what this host needs -- no Ubuntu-specific bits
 ;; here, they follow /etc/os-release.
 (services (niri-desktop-home-services)))
