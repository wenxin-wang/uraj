(define-module (maak)
  #:use-module (guix build utils)
  #:use-module (maak dsl)
  #:use-module (ice-9 threads)
  #:use-module (uraj maak guix)
  #:use-module (uraj utils file path)
  #:re-export (guix)
  #:export (update-channels-lock compile-guix))

(define (update-channels-lock)
  (let ((tmp-output-filename (guix-env-path "channels-lock.scm.tmp")))
    ;; `$` runs commands via `system`, so the redirect must happen in the
    ;; shell: `with-output-to-file` only rebinds Guile's output port and
    ;; would capture maak's "Executing:" log instead of guix's output.
    ($ (list (~ "guix time-machine --channels=~a -- describe -f channels > ~a"
                (guix-env-path "channels.scm")
                tmp-output-filename)))
    (unless (dry-run?)
      (rename-file tmp-output-filename (guix-env-path "channels-lock.scm")))))

(define (compile-guix)
  ($ '("git" "submodule" "update" "--init"))
  (with-directory-excursion (guix-env-path "channels/guix")
    (unless (file-exists? "Makefile")
      ($ '("./bootstrap"))
      ($ '("./configure")))
    ($ `("make" "-j" ,(number->string (current-processor-count))))))
