(define-module (uraj maak guix)
  #:use-module (uraj maak process)
  #:use-module (uraj utils file path)
  #:export (my-fork?
            $guix
            guix))

;; 用环境变量而不是 task 选项:maak 的 CLI 解析器会拒绝传给 task 的 --xxx 选项。
(define (my-fork?)
  (getenv "MY_FORK"))

(define* ($guix args #:key (fork? (my-fork?)))
  (let ((command
         (if fork?
             (append (list (guix-env-path "pre-inst-env") "guix") args)
             (append (list "guix" "time-machine"
                           (string-append "--channels="
                                          (guix-env-path "channels-lock.scm"))
                           "--")
                     args))))
    (run-command command)))

(define* (guix . args)
  ($guix args))
