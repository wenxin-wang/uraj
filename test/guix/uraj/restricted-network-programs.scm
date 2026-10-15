;;; guix build -L src/guix -L src/guile -f test/guix/uraj/restricted-network-programs.scm
;;; Execute generated entry points in the build sandbox without touching
;;; Docker, nftables, host state directories or Android devices.
(use-modules (guix gexp)
             (uraj services restricted-network)
             (uraj services redroid))

(define (smoke-program program module entry)
  ;; The nested production gexp supplies ALL module/extension metadata.
  ;; Do not add with-imported-modules here: that would hide missing imports.
  (program-file (string-append (program-file-name program) "-smoke")
    #~(begin
        (define invoked? #f)
        (unless (procedure? (module-ref (resolve-interface '#$module) '#$entry))
          (error "Missing runtime entry point" '#$module '#$entry))
        ;; Replace only the side-effecting entry point after its real module
        ;; and transitive dependencies have loaded successfully.
        (module-set! (resolve-module '#$module) '#$entry
                     (lambda args (set! invoked? #t)))
        #$(program-file-gexp program)
        (unless invoked?
          (error "Generated program did not invoke its entry point" '#$entry)))))

(define network-smoke
  (smoke-program
   (restricted-network-program
    (restricted-network-configuration (networks (list %redroid-network))))
   '(uraj build restricted-network) 'ensure-restricted-networks))

(define redroid-smoke
  (smoke-program (redroid-prepare-program (redroid-configuration))
                 '(uraj build redroid) 'prepare-redroid))

(computed-file "restricted-network-programs-tested"
  #~(begin
      ;; Spawn each program with only its generated store load paths.
      (unsetenv "GUILE_LOAD_PATH")
      (unsetenv "GUILE_LOAD_COMPILED_PATH")
      (for-each
       (lambda (program)
         (unless (zero? (system* program))
           (error "Generated program failed in clean environment" program)))
       (list #$network-smoke #$redroid-smoke))
      (call-with-output-file #$output
        (lambda (port) (display "Both generated entry points passed.\n" port)))))
