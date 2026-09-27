(define-module (uraj home llm)
  #:use-module (gnu home)
  #:use-module (gnu home services)
  #:use-module (gnu packages)
  #:use-module (gnu services)
  #:use-module (uraj packages llm)
  #:export (llm-home-services))

(define llm-packages
  (cons codex
        (specifications->packages '("claude-code"))))

(define (llm-home-services)
  (list
   (simple-service 'llm-packages
                   home-profile-service-type
                   llm-packages)))
