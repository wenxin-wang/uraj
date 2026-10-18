;;; Unmodified upstream source with a local headless container entrypoint.
(define-module (uraj packages mower)
  #:use-module (guix download)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (gnu packages base)
  #:use-module (gnu packages compression)
  #:use-module (uraj packages docker)
  #:use-module (uraj packages maa)
  #:use-module (uraj utils file path)
  #:use-module (uraj utils gexp)
  #:export (%mower-commit %mower-source %mower-image-tag
            %mower-image-context %mower-build-image))

(define %mower-commit "0e151ae323923952683a173b8f073c8ff8103a92")

(define %mower-source
  (origin
    (method url-fetch)
    (uri (string-append "https://codeload.github.com/ArkMowers/arknights-mower/tar.gz/"
                        %mower-commit))
    (file-name (string-append "mower-" %mower-commit ".tar.gz"))
    (sha256 (base32 "19c9b61klp808v6s2lj7pyll4plyhah0jy5b6725za063zd3r2kj"))))

(define %mower-image-tag "localhost/uraj-mower:4.1.6-alpha.12-0e151ae32392")

(define %mower-image-context
  (computed-file "mower-image-context"
    (with-imported-modules '((guix build utils))
      #~(begin
          (use-modules (guix build utils))
          (mkdir-p (string-append #$output "/source"))
          (setenv "PATH" #$(file-append gzip "/bin"))
          (invoke #$(file-append tar "/bin/tar") "-xzf" #$%mower-source
                  "--strip-components=1" "-C" (string-append #$output "/source"))
          ;; Use the original Linux payload, not the Guix-patched package.
          (copy-file #$(package-source maa-assistant-arknights)
                     (string-append #$output "/maa.tar.gz"))
          (copy-file #$(local-file (project-path "env/mower/Dockerfile"))
                     (string-append #$output "/Dockerfile"))
          (copy-file #$(local-file (project-path "env/mower/entrypoint"))
                     (string-append #$output "/entrypoint"))
          (copy-file #$(local-file (project-path "env/mower/bootstrap.py"))
                     (string-append #$output "/bootstrap.py"))))))

(define %mower-build-image
  (program-file "mower-build-image"
    (with-uraj-modules '((uraj build mower))
      #~(begin
          (use-modules (uraj build mower))
          (ensure-mower-image #$(file-append docker-full "/bin/docker")
                              #$%mower-image-tag #$%mower-image-context)))))
