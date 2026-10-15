(define-module (uraj utils gexp)
  #:use-module (guix gexp)
  #:use-module (guix modules)
  #:export (with-uraj-modules))

(define (runtime-module? name)
  ;; Guix's default selector drops third-party modules, including roots.
  ;; Guile supplies its built-ins; other libraries belong in with-extensions.
  (or (guix-module-name? name)
      (and (pair? name) (eq? (car name) 'uraj))))

(define-syntax-rule (with-uraj-modules modules body ...)
  "Mark gexps in BODY as requiring MODULES and their uraj/guix/gnu source
dependencies.  MODULES lists entry modules, not their transitive imports.
External Guile libraries still need with-extensions.  Dynamically resolved
modules must be listed explicitly when absent from define-module imports."
  (with-imported-modules
      (source-module-closure modules #:select? runtime-module?)
    body ...))
