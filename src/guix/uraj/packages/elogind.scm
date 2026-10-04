(define-module (uraj packages elogind)
  #:use-module (gnu packages admin)
  #:use-module (gnu packages freedesktop)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:export (elogind-with-shepherd-kexec))

;; elogind invokes its kexec helper without arguments.  Raw kexec-tools
;; interprets that as a load request with no kernel, not an orderly reboot.
;; Use Shepherd 1.x explicitly: Guix's default `shepherd' is still 0.10,
;; whose reboot client does not support --kexec.
(define %shepherd-kexec
  (program-file "elogind-shepherd-kexec"
    #~(execl #$(file-append shepherd-1.0 "/sbin/reboot")
             "reboot" "--kexec")))

(define elogind-with-shepherd-kexec
  (let ((base (or (package-replacement elogind) elogind)))
    (package
      (inherit base)
      ;; Keep Guix's security/packaging fixes, but do not graft the original
      ;; replacement over this locally modified build.
      (replacement #f)
      (arguments
       (substitute-keyword-arguments (package-arguments base)
         ((#:configure-flags flags #~'())
          #~(map (lambda (flag)
                   (if (string-prefix? "-Dkexec-path=" flag)
                       (string-append "-Dkexec-path=" #$%shepherd-kexec)
                       flag))
                 #$flags)))))))
