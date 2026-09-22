(define-module (uraj packages input-methods)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages fcitx5)
  #:use-module (guix build-system trivial)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:export (fcitx5-replace))

;;; fcitx5 must start with --replace.  A plain start exits with status 0
;;; when another instance owns the D-Bus name (e.g. a stray left by the
;;; tray "Restart" action, which double-forks), so Shepherd's respawn
;;; would re-spawn it until the respawn limit disables the service.
;;; With --replace the new instance takes the name and the stray exits.
(define fcitx5-replace
  (package
    (name "fcitx5-replace")
    (version (package-version fcitx5))
    (source #f)
    (build-system trivial-build-system)
    (arguments
     (list
      #:modules '((guix build utils))
      #:builder
      #~(begin
          (use-modules (guix build utils))
          (let ((bin (string-append #$output "/bin")))
            (mkdir-p bin)
            (call-with-output-file (string-append bin "/fcitx5")
              (lambda (port)
                (format port "#!~a~%exec ~a -r \"$@\"~%"
                        #$(file-append bash-minimal "/bin/bash")
                        #$(file-append fcitx5 "/bin/fcitx5"))))
            (chmod (string-append bin "/fcitx5") #o755)))))
    (propagated-inputs (list fcitx5))
    (home-page (package-home-page fcitx5))
    (synopsis "fcitx5 launcher that replaces a running instance")
    (description
     "Starts fcitx5 with @code{--replace}, so a fresh instance takes the
D-Bus name from a stray one instead of exiting.")
    (license (package-license fcitx5))))
