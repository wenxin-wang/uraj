(define-module (uraj packages ssh)
  #:use-module (gnu packages kde-plasma)
  #:use-module (gnu packages qt)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module (uraj utils file path)
  #:export (ksshaskpass-with-qtkeychain))

;; Plasma 6.7 requires a newer Qt/KF stack than our channels provide.  Backport
;; upstream 46c7a4294babcfed9f0db064e407416b8bfb5b47 instead.  The patch is
;; rebased onto 6.5.5 without adding new password-handling logic.
;; TODO: Once our channels provide ksshaskpass with this QtKeychain change
;; and compatible Qt/KF dependencies, use the upstream package in basic-desktop
;; and remove this override and patches/ksshaskpass-qtkeychain.patch.  Re-run
;; test/python/uraj/guix/keyring/askpass.py before dropping the backport.
(define ksshaskpass-with-qtkeychain
  (package
    (inherit ksshaskpass)
    (version (string-append (package-version ksshaskpass) "-qtkeychain"))
    (source
     (origin
       (inherit (package-source ksshaskpass))
       (patches
        (append (origin-patches (package-source ksshaskpass))
                (list (local-file
                       (project-path
                        "src/guix/uraj/packages/patches/ksshaskpass-qtkeychain.patch")))))))
    (inputs
     (modify-inputs (package-inputs ksshaskpass)
       (replace "kwallet" qtkeychain-qt6)))
    (synopsis "SSH password prompt with Secret Service support")
    (description
     "Ksshaskpass prompts for SSH passwords and can remember them through
QtKeychain.  In non-KDE sessions it uses libsecret to access the session's
Secret Service, such as GNOME Keyring.  It does not start an SSH agent.")))
