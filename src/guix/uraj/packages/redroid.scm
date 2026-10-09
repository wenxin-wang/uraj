(define-module (uraj packages redroid)
  #:use-module (guix packages)
  #:use-module (guix gexp)
  #:use-module (guix utils)
  #:use-module (guix build-system gnu)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (gnu packages base)
  #:export (redroid-init))

(define redroid-init
  (package
    (name "redroid-init")
    (version "0.1")
    (source (local-file "aux-files/redroid-init.c"))
    (build-system gnu-build-system)
    (inputs (list `(,glibc "static")))
    (arguments
     (list
      #:tests? #f ; Mount/exec behavior requires a privileged Android container.
      #:phases
      #~(modify-phases %standard-phases
          (replace 'unpack
            (lambda* (#:key source #:allow-other-keys)
              (copy-file source "redroid-init.c")))
          (delete 'configure)
          (replace 'build
            (lambda _
              (invoke #$(cc-for-target) "-static" "-Os" "-Wall" "-Wextra"
                      "-Werror" "redroid-init.c" "-o" "redroid-init")))
          (replace 'install
            (lambda _ (install-file "redroid-init" (string-append #$output "/bin")))))))
    (home-page "https://github.com/remote-android/redroid-doc")
    (synopsis "Protect host module loading before starting Android")
    (description "A static entrypoint that makes the modprobe sysctl read-only
inside the container mount namespace, then executes Android init.  It needs
neither Android's not-yet-mounted APEX libraries nor the host GNU store.")
    (license license:gpl3+)))
