(define-module (uraj packages libinput)
  #:use-module (gnu packages freedesktop)
  #:use-module (gnu packages lua)
  #:use-module (gnu packages window-management)
  #:use-module (guix gexp)
  #:use-module (guix git-download)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:export (libinput-minimal-with-lua-plugins
            niri-with-libinput-plugins))

;;; libinput >= 1.30 runs Lua plugins that may rewrite a device's evdev
;;; frames before libinput sees them.  niri loads them from
;;; $XDG_CONFIG_HOME/libinput/plugins and the default paths, but only
;;; when built against a libinput that has the plugin system (niri's
;;; build.rs probes for >= 1.30).  Guix master 64d4de2 still packages
;;; 1.29.1, so niri is rebuilt against the variant below.  Drop both
;;; once Guix's libinput is >= 1.30 with Lua enabled.
;;;
;;; The plugin itself is a dotfile, see
;;; env/dotfiles/desktop/niri/.config/libinput/plugins.

(define libinput-minimal-with-lua-plugins
  (package
    (inherit libinput-minimal)
    (version "1.32.0")
    (source (origin
              (method git-fetch)
              (uri (git-reference
                    (url "https://gitlab.freedesktop.org/libinput/libinput.git")
                    (commit version)))
              (file-name (git-file-name "libinput" version))
              (sha256
               (base32
                "10rfai8f4djpkc4m15w0ccdw3pw6z5mcwhxp554fvdzzlqbfgyww"))))
    (arguments
     (substitute-keyword-arguments (package-arguments libinput-minimal)
       ;; meson looks for lua-5.4.pc; Guix's default lua is 5.3.
       ((#:configure-flags flags ''())
        `(cons "-Dlua-plugins=enabled" ,flags))))
    (inputs
     (modify-inputs (package-inputs libinput-minimal)
       (append lua-5.4)))))

(define niri-with-libinput-plugins
  (package
    (inherit niri)
    (inputs
     (modify-inputs (package-inputs niri)
       (replace "libinput-minimal" libinput-minimal-with-lua-plugins)))))
