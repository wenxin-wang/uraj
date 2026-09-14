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
  #:use-module (uraj maak guix)
  #:use-module (uraj utils file path)
  #:re-export (guix)
  #:export (update-channels-lock compile-guix system-vm home-container home-reconfigure))

(define (update-channels-lock)
  (let ((tmp-output-filename (guix-env-path "channels-lock.scm.tmp")))
    (with-output-to-file tmp-output-filename
      (lambda ()
        (time-machine '("describe" "-f" "channels")
                      #:channels (guix-env-path "channels.scm"))))
    (unless (dry-run?)
      (rename-file tmp-output-filename (guix-env-path "channels-lock.scm")))))

(define (compile-guix)
  ($ '("git" "submodule" "update" "--init"))
  (with-directory-excursion (guix-env-path "channels/guix")
    (unless (file-exists? "Makefile")
      ($ '("./bootstrap"))
      ($ '("./configure")))
    ($ `("make" "-j" ,(number->string (current-processor-count))))))

(define extra-guix-args
  `("-L" ,(project-path "src/guix")))

(define* (system-vm #:optional (config-path (guix-env-path "os/qemu-example.scm")))
  ($guix `("system" "vm" ,@extra-guix-args ,config-path)))

(define* (home-container #:optional (config-path (guix-env-path "os/home-example.scm"))
	                 #:key (fork? (my-fork?))
                         (command '())
                         . args)
  "Run the home environment in a container, sharing the host's display and audio."
  (let ((command* (if (pair? args) args command)))
    (match (desktop-container-envs)
      ((shares . env)
       (let* ((script (and (pair? env)
                           (string-append "'"
                                          (string-join (map (cut string-append "export " <>) env) ";")
                                          (if (null? command*) ";exec /proc/self/exe'" ";'"))))
              (head `("home" "container" ,@extra-guix-args ,config-path
                      ;; Only the fork supports this option.
                      ,@(if fork? '("--keep-host-uid-gid") '())
                      ,@shares))
              (tail (cond ((pair? env)    `("--" ,script ,@command*))
                          ((pair? command*) `("--" ,@command*))
                          (else            '()))))
         ($guix (append head tail) #:fork? fork?))))))

(define* (home-reconfigure #:optional (config-path (guix-env-path "os/home-example.scm")))
  ($guix `("home" "reconfigure" ,@extra-guix-args ,config-path)))
