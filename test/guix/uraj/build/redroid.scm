;;; guix repl -L src/guix test/guix/uraj/build/redroid.scm
(use-modules (guix build utils) (ice-9 textual-ports) (srfi srfi-64)
             (uraj build redroid))

;; A fake docker whose daemon answers from the second query, and whose
;; container survives the first `rm', as when removal is already in progress.
(define directory (mkdtemp (string-append (or (getenv "TMPDIR") "/tmp")
                                          "/redroid-build.XXXXXX")))
(define docker (string-append directory "/docker"))
(define (state name) (string-append directory "/" name))
(define (touch file) (call-with-output-file file (const #t)))
(define (calls)
  (if (file-exists? (state "calls"))
      (call-with-input-file (state "calls") get-string-all)
      ""))
(call-with-output-file docker
  (lambda (port)
    (format port "#!~a
d=~a
echo \"$*\" >> \"$d/calls\"
case \"$1\" in
  version) [ -e \"$d/up\" ] || { touch \"$d/up\"; exit 1; } ;;
  container) [ -e \"$d/exists\" ] && echo 0123 || exit 1 ;;
  rm) if [ -e \"$d/busy\" ]; then rm \"$d/exists\"; else touch \"$d/busy\"; exit 1; fi ;;
esac
" (which "sh") directory)))
(chmod docker #o755)

(test-begin "redroid-build")
(touch (state "exists"))
(test-assert "waits for Docker, then retries until the container is gone"
  (begin (prepare-redroid-container docker "redroid-maa" #:attempts 5)
         (not (file-exists? (state "exists")))))
(test-equal "removes only the named container" 2
  (length (filter (lambda (line) (string=? line "rm --force redroid-maa"))
                  (string-split (calls) #\newline))))
(delete-file (state "calls"))
(test-assert "an absent container needs no removal"
  (begin (prepare-redroid-container docker "redroid-maa" #:attempts 1)
         (not (string-contains (calls) "rm "))))
(delete-file (state "up"))
(call-with-output-file docker
  (lambda (port) (format port "#!~a\nexit 1\n" (which "sh"))))
(test-error "gives up when Docker never answers" #t
  (prepare-redroid-container docker "redroid-maa" #:attempts 1))
(define failures (test-runner-fail-count (test-runner-current)))
(test-end "redroid-build")
(delete-file-recursively directory)
(exit (if (zero? failures) 0 1))
