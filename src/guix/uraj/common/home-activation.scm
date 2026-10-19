(define-module (uraj common home-activation)
  #:use-module (gnu packages python)
  #:use-module (guix gexp)
  #:use-module (uraj utils file path)
  #:export (home-activation-program))

(define home-activation-program
  (program-file
   "home-activation"
   #~(apply execl #$(file-append python "/bin/python3") "python3"
            #$(local-file (project-path "src/python/uraj/home/activation.py"))
            (cdr (command-line)))))
