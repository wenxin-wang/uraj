(define-module (uraj packages noctalia)
  #:use-module (gnu packages elf)
  #:use-module (guix build-system trivial)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:export (noctalia-with-host-pam))

(define (noctalia-with-host-pam noctalia pam-libs)
  "Return NOCTALIA with PAM-LIBS, a list of absolute file names of the
host's PAM stack and its dependency closure, added as DT_NEEDED entries.

Noctalia's in-process screen locker parses the host's /etc/pam.d files
and loads the host's PAM modules; those modules live in the multiarch
directory, which the Guix loader cannot reach.  patchelf --add-needed
prepends the closure to the binary's DT_NEEDED list, so the host
libraries load first and the original @code{libpam.so.0} entry is
satisfied by the host's copy -- the same load order an LD_PRELOAD of the
closure produces, but without any environment variable that could leak
into programs noctalia spawns."
  (package
    (inherit noctalia)
    (name "noctalia-with-host-pam")
    (source #f)
    (build-system trivial-build-system)
    (arguments
     (list
      #:modules '((guix build utils))
      #:builder
      #~(begin
          (use-modules (guix build utils))
          (copy-recursively #$noctalia #$output)
          (let ((bin (string-append #$output "/bin/noctalia")))
            ;; The copy keeps the store's read-only permissions.
            (chmod bin #o755)
            (for-each (lambda (lib)
                        (invoke #$(file-append patchelf "/bin/patchelf")
                                "--add-needed" lib bin))
                      '#$pam-libs)))))
    (inputs (list noctalia))
    (native-inputs (list patchelf))))
