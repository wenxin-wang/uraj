(define-module (uraj utils file path)
  #:export (project-root
            project-path
            guix-env-path))

(define project-root
  (let ((here (or (current-filename)
                  (%search-load-path "uraj/utils/file/path.scm"))))
    (canonicalize-path (string-append (dirname here) "/../../../../.."))))

(define (project-path relative)
  (string-append project-root "/" relative))

(define (guix-env-path relative)
  (project-path (string-append "env/guix/" relative)))
