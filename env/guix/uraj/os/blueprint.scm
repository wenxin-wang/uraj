(use-modules (ice-9 match)
             (ice-9 threads)
             (oop goops)
             (srfi srfi-1)
             (srfi srfi-19)
             (srfi srfi-26)
             (blue build)
             (blue computation)
             (blue subprocess)
             (blue types blueprint)
             (blue types buildable)
             (blue types command)
             (blue types configuration)
             (blue types variable))

(define project-root
  (canonicalize-path (string-append (car %load-path) "/../../../..")))

(define (project-path relative)
  (string-append project-root "/" relative))

(define ($ cmd)
  (match cmd
    ((prog . args)
     (let ((exit-val (popen prog args #:error (current-error-port))))
       (zero? exit-val)))))

(define-command (update-channels-lock-comand arguments)
  ((invoke "update-channels-lock")
   (category 'development)
   (synopsis "Update channels lock"))
  (with-output-to-file (project-path "env/guix/uraj/channels-lock.scm")
    (lambda ()
      ($ `("guix" "time-machine" "-C"
           ,(project-path "env/guix/uraj/channels.scm") "--"
           "describe" "-f" "channels")))))

(blueprint
 (commands
  (list update-channels-lock-comand)))
