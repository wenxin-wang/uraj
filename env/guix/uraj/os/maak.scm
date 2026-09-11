(define-module (maak)
  #:declarative? #t
  #:use-module (maak maak)
  #:use-module (ice-9 match)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 threads)
  #:use-module (oop goops)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-19)
  #:use-module (srfi srfi-26))

(define project-root
  (canonicalize-path (string-append (dirname (current-filename)) "/../../../..")))

(define (project-path relative)
  (string-append project-root "/" relative))

(define (update-channels-lock)
  (let* ((tmp-output-filename (project-path "env/guix/uraj/channels-lock.scm.tmp"))
         (update-result (with-output-to-file tmp-output-filename
                          (lambda ()
                            (system* "guix" "time-machine" "-C"
                                     (project-path "env/guix/uraj/channels.scm") "--"
                                     "describe" "-f" "channels")))))
    (when (eq? update-result 0)
      (rename-file tmp-output-filename (project-path "env/guix/uraj/channels-lock.scm")))))
