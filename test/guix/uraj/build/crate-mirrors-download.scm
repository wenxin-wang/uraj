;;; Network integration check (downloads one small crate):
;;; guix time-machine -C env/guix/channels-lock.scm -- build -L src/guix \
;;;   --no-grafts --no-substitutes -f test/guix/uraj/build/crate-mirrors-download.scm
(use-modules (guix gexp) (guix monads) (guix store)
             (guix packages) (guix derivations)
             (guix build-system cargo) (guix base32)
             (gnu services base) (uraj services guix-mirrors))

(define hash "1msc8g8x8a9dy3l85ila4sijvnhr1rxrxsbjhqk1bawkm64lc6c9")
(define source (crate-source "imgref" "1.12.2" hash))
(define helper
  (guix-mirror-command (guix-configuration-guix (guix-configuration))))

(with-store store
  (run-with-store store
    (mlet %store-monad ((drv (origin->derivation source)))
      (gexp->derivation
       "crate-mirror-download-check"
       #~(begin
           ;; The unmodified perform-download opens these files inside the
           ;; build sandbox; retain all original mirror metadata as inputs.
           (define metadata '#$(derivation-sources drv))
           (execl #$helper #$helper "perform-download"
                  #$(raw-derivation-file drv) #$output))
       #:hash-algo 'sha256
       #:hash (nix-base32-string->bytevector hash)
       #:recursive? #f))))
