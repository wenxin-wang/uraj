;;; shikanox's nix-go build system defaults to GOAMD64=v3.  Storie's
;;; Celeron J6412 has no AVX/AVX2, so its plugins need the baseline ISA.
(define-module (uraj packages docker)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module ((shika packages docker) #:prefix shika:)
  #:export (docker-full))

(define (baseline-amd64 package)
  (package/inherit package
    (arguments
     (substitute-keyword-arguments (package-arguments package)
       ((#:phases phases)
        `(modify-phases ,phases
           (add-before 'build 'baseline-amd64
             (lambda _ (setenv "GOAMD64" "v1")))))))))

(define docker-full
  ((package-input-rewriting
    `((,shika:docker-compose . ,(baseline-amd64 shika:docker-compose))
      (,shika:docker-buildx . ,(baseline-amd64 shika:docker-buildx))))
   shika:docker-full))
