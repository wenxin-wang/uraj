(use-modules (guix packages)
             (guix profiles)
             (gnu packages))

(concatenate-manifests
 (list (specifications->manifest
        (list "gnupg"
              "maak"
              "sops"))))
