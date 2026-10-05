(define-module (uraj services guix-mirrors)
  #:use-module (guix gexp)
  #:export (guix-mirror-command))

(define %mirror-modules
  (file-union
   "guix-crate-mirror-modules"
   `(("uraj/build/crate-mirrors.scm"
      ,(local-file
        (canonicalize-path
         (search-path %load-path "uraj/build/crate-mirrors.scm")))))))

(define %download-driver
  (scheme-file
   "guix-perform-download-with-crate-mirrors.scm"
   #~(begin
       (use-modules (guix scripts perform-download)
                    (uraj build crate-mirrors))
       (call-with-crate-mirrors
        (lambda ()
          (apply guix-perform-download (cdr (command-line))))))))

(define (guix-mirror-command guix)
  "Wrap GUIX for the daemon, adding crate mirrors to builtin downloads."
  (program-file
   "guix-with-crate-mirrors"
   #~(let ((guix #$(file-append guix "/bin/guix"))
           (args (cdr (command-line))))
       (if (and (pair? args) (string=? (car args) "perform-download"))
           (apply execl guix guix "repl" "-q"
                  "-L" #$%mirror-modules #$%download-driver (cdr args))
           ;; substitute, offload, authenticate, gc, etc. use unmodified Guix.
           (apply execl guix guix args)))))
