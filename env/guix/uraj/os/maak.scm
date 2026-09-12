(define-module (maak)
  #:declarative? #t
  #:use-module (guix build utils)
  #:use-module (maak dsl)
  #:use-module (maak maak)
  #:use-module (ice-9 match)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 threads)
  #:use-module (oop goops)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-19)
  #:use-module (srfi srfi-26)
  #:use-module (uraj desktop env)
  #:export (update-channels-lock guix guix-my compile-guix home-container))

(define project-root
  (canonicalize-path (string-append (dirname (current-filename)) "/../../../..")))

(define (project-path relative)
  (string-append project-root "/" relative))

(define (guix-uraj-path relative)
  (project-path (string-append "env/guix/uraj/" relative)))

(define (update-channels-lock)
  (let ((tmp-output-filename (guix-uraj-path "channels-lock.scm.tmp")))
    (with-output-to-file tmp-output-filename
      (lambda ()
        (time-machine '("describe" "-f" "channels")
                      #:channels (guix-uraj-path "channels.scm"))))
    (unless (dry-run?)
      (rename-file tmp-output-filename (guix-uraj-path "channels-lock.scm")))))

(define* ($guix args #:key (fork? #f))
  (if fork?
      ($ `(,(guix-uraj-path "pre-inst-env") "guix" ,@args))
      (time-machine args #:channels (guix-uraj-path "channels-lock.scm"))))

(define* (guix . args)
  ($guix args))

(define* (guix-my . args)
  ($guix args #:fork? #t))

(define (compile-guix)
  ($ '("git" "submodule" "update" "--init"))
  (with-directory-excursion (guix-uraj-path "channels/guix")
    (unless (file-exists? "Makefile")
      ($ '("./bootstrap"))
      ($ '("./configure")))
    ($ `("make" "-j" ,(number->string (current-processor-count))))))

(define* (home-container #:key (config-path (guix-uraj-path "os/home-example.scm"))
                         (command '()))
  "Run the home environment in a container, sharing the host's display and audio."
  (match (desktop-container-envs)
    ((shares . env)
     (let* ((script (and (pair? env)
                         (string-append "'"
                                        (string-join (map (cut string-append "export " <>) env) ";")
                                        (if (null? command) ";exec /proc/self/exe'" ";'"))))
            (head `("home" "container" ,config-path ,@shares))
            (tail (cond ((pair? env)    `("--" ,script ,@command))
                        ((pair? command) `("--" ,@command))
                        (else            '()))))
       ($guix (append head tail))))))
