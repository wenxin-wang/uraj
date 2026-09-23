(define-module (uraj hardware asus)
  #:use-module (guix gexp)
  #:use-module (guix modules)
  #:use-module (uraj packages asus)
  #:export (asus-adolbook-air14-acpi-hack))

;;; The kernel takes ACPI table overrides from the initrd
;;; (Documentation/admin-guide/acpi/initrd_table_override.rst): an
;;; *uncompressed* cpio archive containing kernel/firmware/acpi/*.aml
;;; must come before any compressed archive, because lib/earlycpio.c
;;; stops parsing at the first compressed byte.  The archive is
;;; therefore prepended to BASE-INITRD, whose own uncompressed microcode
;;; archive keeps working for the same reason.
;;;
;;; The result carries a ".gz" name on purpose even though nothing is
;;; compressed: the iso9660 zisofs filter in (gnu build image) leaves
;;; only such names uncompressed, and GRUB cannot read through zisofs
;;; (see the comment on desktop-initrd in desktop-iso.scm).

;; (guix build store-copy), which the closure of (gnu build linux-initrd)
;; pulls in, autoloads (guix store deduplication), so the latter can be
;; left out; without this the build would need Guile-Gcrypt, which the
;; builder's Guile does not have (expression->initrd does the same in
;; (gnu system linux-initrd)).
(define (import-module? module)
  (and (guix-module-name? module)
       (not (equal? module '(guix store deduplication)))))

(define (asus-adolbook-air14-acpi-hack base-initrd)
  "Return an initrd maker, for the @code{initrd} field of an
@code{operating-system}, that extends BASE-INITRD (e.g.
@code{microcode-initrd}) with the patched SSDT10 of
@code{asus-adolbook-air14-hacked-acpi-table}."
  (lambda (file-systems . rest)
    (let ((base (apply base-initrd file-systems rest)))
      (computed-file "asus-adolbook-air14-initrd.gz"
        (with-imported-modules (source-module-closure
                                '((gnu build linux-initrd)
                                  (guix build utils))
                                #:select? import-module?)
          #~(begin
              (use-modules (gnu build linux-initrd)
                           (guix build utils))

              (mkdir-p "kernel/firmware/acpi")
              (copy-file #$(file-append asus-adolbook-air14-hacked-acpi-table
                                        "/usr/share/acpi/SSDT10.aml")
                         "kernel/firmware/acpi/SSDT10.aml")
              (write-cpio-archive "acpi_override" "kernel" #:compress? #f)

              (call-with-output-file #$output
                (lambda (port)
                  (for-each (lambda (file)
                              (call-with-input-file file
                                (lambda (input)
                                  (dump-port input port))))
                            (list "acpi_override" #$base)))
                #:binary #t)))))))
