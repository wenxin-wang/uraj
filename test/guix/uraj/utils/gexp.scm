;;; guix repl -L src/guix -L src/guile test/guix/uraj/utils/gexp.scm
(use-modules (gnu services) (guix gexp) (guix modules)
             (srfi srfi-1) (srfi srfi-34) (srfi srfi-64)
             (uraj utils gexp) (uraj common basic-services)
             (uraj home llm) (uraj home paseo))

(test-begin "uraj-utils-gexp")

(define runtime-modules
  (gexp-modules
   (with-uraj-modules '((uraj build restricted-network)) #~#t)))

(test-assert "entry and transitive local/Guix imports are included"
  (every (lambda (name) (member name runtime-modules))
         '((uraj build restricted-network)
           (uraj build restricted-network-docker)
           (uraj network-policy) (guix build utils) (guix records))))
(test-assert "built-ins and extension libraries are not copied as sources"
  (not (any (lambda (name) (memq (car name) '(ice-9 srfi json)))
            runtime-modules)))
(test-assert "GNU entry modules are also supported"
  (member '(gnu build activation)
          (gexp-modules (with-uraj-modules '((gnu build activation)) #~#t))))
(test-assert "missing local modules fail during gexp construction"
  (guard (condition ((missing-dependency-error? condition) #t))
    (with-uraj-modules '((uraj nonexistent-runtime-module)) #~#t)
    #f))

(test-assert "contained-agent discovers its SSH helper"
  (every (lambda (name)
           (member name (gexp-modules (program-file-gexp contained-agent))))
         '((uraj bin contained-agent) (uraj bin contained-ssh))))
(test-assert "Paseo discovers both contained-agent and its SSH helper"
  (every (lambda (name)
           (member name
                   (gexp-modules (program-file-gexp paseo-sandbox-program))))
         '((uraj bin paseo-sandbox) (uraj bin contained-agent)
           (uraj bin contained-ssh))))

(test-assert "single-file activation carries its template module"
  (member '(uraj utils file template)
          (gexp-modules
           (service-value
            (block-in-file-activation-service
             (string-append (getcwd) "/AGENTS.md") "/unused-target")))))
(test-assert "directory activation carries its template module"
  (member '(uraj utils file template)
          (gexp-modules
           (service-value
            (block-in-files-activation-service
             (string-append (getcwd) "/env/dotfiles/llm"))))))

(define failures (test-runner-fail-count (test-runner-current)))
(test-end "uraj-utils-gexp")
(exit (if (zero? failures) 0 1))
