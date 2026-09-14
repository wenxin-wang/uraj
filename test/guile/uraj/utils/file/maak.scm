(define-module (maak)
  #:declarative? #t
  #:use-module (maak dsl)
  #:use-module (uraj utils file path)
  #:export (test default))

(define (test)
  "Run the unit tests for (uraj utils file template)."
  ($ `("guile" ,(project-path "test/guile/uraj/utils/file/template.scm"))))

(define (default)
  "Run the unit tests for (uraj utils file template)."
  (test))
