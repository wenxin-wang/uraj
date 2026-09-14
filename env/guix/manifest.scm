(use-modules (guix packages)
             (guix profiles)
             (gnu packages))

(define (specifications->development-manifest specs)
  (let ((specification->development-manifest
         (compose package->development-manifest
                  specification->package)))
    (concatenate-manifests
     (map specification->development-manifest specs))))

(concatenate-manifests
 (list (specifications->manifest
        (list "gnupg"
              "maak"
	      ;; `guix` development-manifest introduces `git`, and thus the
	      ;; need for `nss-certs` for certificates on installations without
	      ;; guix-os/guix-home.
              "nss-certs"
              "sops"
              ;; For Guix System installer.
              "guile-newt"
              "guile-parted"
              "guile-webutils"))
       (specifications->development-manifest
        (list "guix"))))
