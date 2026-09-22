(define-module (maak)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-26)
  #:use-module (uraj desktop env)
  #:use-module (uraj maak guix)
  #:use-module (uraj utils file path)
  #:export (system-vm build-iso home-container home-reconfigure))

(define* (system-vm #:optional (config-path (guix-env-path "os/qemu-example.scm")))
  ($guix `("system" "vm" ,config-path)))

(define* (build-iso #:optional (config-path (guix-env-path "os/desktop-iso.scm")))
  ($guix `("system" "image" "-t" "iso9660" ,config-path)))

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
              (head `("home" "container" ,config-path
                      ;; Only the fork supports this option.
                      ,@(if fork? '("--keep-host-uid-gid") '())
                      ,@shares))
              (tail (cond ((pair? env)    `("--" ,script ,@command*))
                          ((pair? command*) `("--" ,@command*))
                          (else            '()))))
         ($guix (append head tail) #:fork? fork?))))))

(define* (home-reconfigure #:optional (config-path (guix-env-path "os/home-example.scm")))
  ($guix `("home" "reconfigure" ,config-path)))
