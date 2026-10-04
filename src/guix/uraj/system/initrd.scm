(define-module (uraj system initrd)
  #:use-module (gnu packages linux)
  #:use-module (gnu system linux-initrd)
  #:use-module (guix gexp)
  #:use-module (guix utils)
  #:export (zstd-zswap-initrd))

;; Like base-initrd, but use raw-initrd's pre-mount hook: boot-system
;; invokes it after loading modules and before mounting root/resuming.
(define* (zstd-zswap-initrd file-systems
                          #:key (linux-modules '()) keyboard-layout
                          volatile-root?
                          #:allow-other-keys #:rest rest)
  (apply raw-initrd file-systems
         #:linux-modules
         (append linux-modules '("zstd")
                 (file-system-modules file-systems)
                 (if volatile-root? '("overlay") '()))
         #:helper-packages
         (append (file-system-packages file-systems
                                       #:volatile-root? volatile-root?)
                 (if keyboard-layout (list loadkeys-static) '()))
         #:pre-mount
         #~(begin
             (call-with-output-file "/sys/module/zswap/parameters/compressor"
               (lambda (port) (display "zstd" port)))
             #t)
         (strip-keyword-arguments '(#:linux-modules) rest)))
