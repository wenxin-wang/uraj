(define-module (maak)
  #:declarative? #t
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
  #:export (update-channels-lock guix-time-machine home-container))

(define project-root
  (canonicalize-path (string-append (dirname (current-filename)) "/../../../..")))

(define (project-path relative)
  (string-append project-root "/" relative))

(define (update-channels-lock)
  (let* ((tmp-output-filename (project-path "env/guix/uraj/channels-lock.scm.tmp"))
         (update-result (with-output-to-file tmp-output-filename
                          (lambda ()
                            ($ `("guix" "time-machine" "-C"
                                 ,(project-path "env/guix/uraj/channels.scm") "--"
                                 "describe" "-f" "channels"))))))
    (when (eq? update-result 0)
      (rename-file tmp-output-filename (project-path "env/guix/uraj/channels-lock.scm")))))

(define (guix-time-machine . cmd)
  (time-machine cmd #:channels (project-path "env/guix/uraj/channels-lock.scm")))

(define* (home-container #:key (config-path (project-path "env/guix/uraj/os/home-example.scm"))
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
       (apply guix-time-machine (append head tail))))))
