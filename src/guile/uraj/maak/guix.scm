(define-module (uraj maak guix)
  #:use-module (maak dsl)
  #:export (project-root
            project-path
            guix-env-path
            my-fork?
            $guix
            guix))

(define project-root
  (let ((here (or (current-filename)
                  (%search-load-path "uraj/maak/guix.scm"))))
    (canonicalize-path (string-append (dirname here) "/../../../.."))))

(define (project-path relative)
  (string-append project-root "/" relative))

(define (guix-env-path relative)
  (project-path (string-append "env/guix/" relative)))

;; 用环境变量而不是 task 选项:maak 的 CLI 解析器会拒绝传给 task 的 --xxx 选项。
(define (my-fork?)
  (getenv "MY_FORK"))

(define* ($guix args #:key (fork? (my-fork?)))
  (if fork?
      ($ `(,(guix-env-path "pre-inst-env") "guix" ,@args))
      (time-machine args #:channels (guix-env-path "channels-lock.scm"))))

(define* (guix . args)
  ($guix args))
