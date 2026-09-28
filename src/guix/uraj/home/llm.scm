(define-module (uraj home llm)
  #:use-module (gnu home)
  #:use-module (gnu home services)
  #:use-module (gnu packages)
  #:use-module (gnu services)
  #:use-module (uraj common basic-services)
  #:use-module (uraj packages llm)
  #:use-module (uraj utils file path)
  #:export (llm-home-services))

(define llm-packages
  (cons codex
        (specifications->packages '("claude-code"))))

(define (llm-home-services)
  (append
   (list
    (simple-service 'llm-packages
                    home-profile-service-type
                    llm-packages))
   (my-dotfiles-services (list (project-path "env/dotfiles/llm")))))
