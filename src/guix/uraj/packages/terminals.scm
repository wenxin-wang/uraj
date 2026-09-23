(define-module (uraj packages terminals)
  #:use-module (guix download)
  #:use-module (guix packages)
  #:use-module ((px packages terminals)
                #:select ((ghostty . ghostty-repacked)))
  #:export (ghostty))

;;; The pantherx ghostty repackages dariogriffo's Debian build, which up
;;; to revision +3 statically bundled fontconfig and exported its
;;; symbols.  In-process, those preempted the shared libfontconfig that
;;; GTK4/pango load from the profile: a pattern the latter created could
;;; be destroyed by the bundled 2.14.2 FcPatternDestroy -- a refcount
;;; write at the wrong offset, typically into a read-only font-cache
;;; mapping, which killed ghostty with SIGSEGV whenever fonts were
;;; refreshed (e.g. by `guix home reconfigure').  Revision +4 builds with
;;; -fsys=fontconfig (system fontconfig); see
;;; https://github.com/dariogriffo/ghostty-debian/issues/9
;;; This override tracks that fix.
(define-public ghostty
  (package
    (inherit ghostty-repacked)
    (name "ghostty")
    (version "1.3.1-6")
    (source
     (origin
       (method url-fetch)
       (uri (string-append
             "https://github.com/dariogriffo/ghostty-debian/releases/download/"
             "1.3.1%2B6/ghostty_1.3.1-6.trixie_amd64.deb"))
       (file-name (string-append name "-" version ".deb"))
       (sha256
        (base32 "09c94rv3py0kinydn8iqp2jzbviy15mmgc7xq2x6lxa06q8yf4nh"))))))
