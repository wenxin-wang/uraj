(use-modules (gnu home)
             (gnu packages)
             (gnu packages base))

(home-environment
 (packages (specifications->packages
            (list "swappy"))))
