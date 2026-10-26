;;; guix build -L src/guix -L src/guile -f test/guix/uraj/openclaw-program.scm
;;; Load the generated entry point without host files, credentials or Docker.
(use-modules (guix gexp) (uraj services openclaw))

(define config
  (openclaw-configuration
    (image (string-append "sha256:" (make-string 64 #\a)))
    (secrets-file (plain-file "fixture.yaml" "fixture"))
    (engine-image (string-append "sha256:" (make-string 64 #\c)))
    (sandbox-image (string-append "sha256:" (make-string 64 #\d)))
    (feishu-app-id "cli_test") (model "new-api/test-model")
    (providers (list (openclaw-provider (name "new-api")
                                      (api "openai-responses")
                                      (models '("test-model")))))))

(define smoke
  (program-file "openclaw-prepare-smoke"
    ;; All dependency metadata comes from the production program's gexp.
    #~(begin
        (define invoked? #f)
        (unless (procedure? (module-ref (resolve-interface '(uraj build openclaw))
                                       'prepare-openclaw))
          (error "Missing OpenClaw runtime entry point"))
        ;; Load real dependencies, then replace only filesystem mutations.
        (module-set! (resolve-module '(uraj build openclaw)) 'prepare-openclaw
                     (lambda args (set! invoked? #t)))
        #$(program-file-gexp (openclaw-prepare-program config))
        (unless invoked? (error "Preparation entry point was not invoked")))))

(computed-file "openclaw-program-tested"
  #~(begin
      (unsetenv "GUILE_LOAD_PATH")
      (unsetenv "GUILE_LOAD_COMPILED_PATH")
      (unless (zero? (system* #$smoke))
        (error "Generated OpenClaw program failed in clean environment"))
      (call-with-output-file #$output
        (lambda (port) (display "OpenClaw preparation entry point passed.\n" port)))))
