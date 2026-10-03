(define-module (uraj packages audio)
  #:use-module (gnu packages linux)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module (uraj utils file path)
  #:export (pipewire-with-bluez-release-fix
            wireplumber-with-bluez-release-fix))

;; Guix master 72c8fe21 still packages 1.6.8 without this upstream fix.
;; Remove the override once its PipeWire handles no-reply Release calls.
(define pipewire-with-bluez-release-fix
  (package
    (inherit pipewire)
    (source
     (origin
       (inherit (package-source pipewire))
       (patches
        (append (origin-patches (package-source pipewire))
                (list (local-file
                       (project-path
                        "src/guix/uraj/packages/patches/pipewire-bluez-release-no-reply.patch")))))))))

;; WirePlumber loads the SPA Bluetooth plugin from its PipeWire input.
;; Replacing only the home-pipewire daemon leaves the old plugin in use.
(define wireplumber-with-bluez-release-fix
  (package
    (inherit wireplumber)
    (inputs
     (modify-inputs (package-inputs wireplumber)
       (replace "pipewire" pipewire-with-bluez-release-fix)))))
