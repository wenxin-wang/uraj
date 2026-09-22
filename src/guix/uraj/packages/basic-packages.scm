(define-module (uraj packages basic-packages)
  #:use-module (gnu packages base)
  #:export (glibc-common-locales))

(define glibc-common-locales
  (make-glibc-utf8-locales
   glibc
   #:locales (list "en_US" "zh_CN" "zh_TW" "ja_JP")
   #:name "glibc-common-locales"))
