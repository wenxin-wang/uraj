(define-module (uraj packages asus)
  #:use-module (gnu packages admin)       ;acpica (iasl)
  #:use-module (gnu packages base)        ;patch
  #:use-module (guix build-system trivial)
  #:use-module (guix gexp)
  #:use-module (guix licenses)
  #:use-module (guix packages)
  #:use-module (uraj utils file path)
  #:export (asus-adolbook-air14-hacked-acpi-table))

(define %ssdt10
  (local-file (project-path "vendor/firmware/asus-adolbook-air14/acpi/SSDT10.aml")))

(define %ssdt10-fix
  (local-file (project-path "vendor/firmware/asus-adolbook-air14/acpi/SSDT10.patch")))

;;; The firmware's SSDT10 (AMD "AOD") re-declares the root names \ASMI
;;; and \ISMI that the DSDT defines as methods, so ACPICA cannot create
;;; them and \AOD.PSMI is left without a region object, which
;;; acpi_ex_prep_field_value() dereferences: a kernel panic in
;;; acpi_init, before keyboard, touchpad or graphics come up (see
;;; vendor/firmware/asus-adolbook-air14/acpi/README.md).
;;;
;;; The patch deletes the two colliding names, inlines their constants
;;; where SSDT10 used them and bumps the OEM revision, which the
;;; kernel's initrd table override needs in order to replace the
;;; firmware table (it matches on signature + OEM ID + OEM table ID,
;;; none of which the patch touches).
(define asus-adolbook-air14-hacked-acpi-table
  (package
    (name "asus-adolbook-air14-hacked-acpi-table")
    (version "1")
    (source %ssdt10)
    (build-system trivial-build-system)
    (native-inputs (list acpica patch))
    (arguments
     (list
      #:modules '((guix build utils))
      #:builder
      #~(begin
          (use-modules (guix build utils))
          (let ((iasl #$(file-append acpica "/bin/iasl"))
                (patch #$(file-append patch "/bin/patch")))
            ;; Disassemble, patch the ASL, assemble the table again.  The
            ;; copy of the dump keeps the store's read-only permissions and
            ;; iasl will not assemble over it.
            (copy-file #$%ssdt10 "SSDT10.aml")
            (make-file-writable "SSDT10.aml")
            (invoke iasl "-d" "SSDT10.aml")
            (invoke patch "-p1" "-i" #$%ssdt10-fix)
            (invoke iasl "-tc" "-p" "SSDT10" "SSDT10.dsl")
            (install-file "SSDT10.aml"
                          (string-append #$output "/usr/share/acpi"))))))
    (home-page #f)
    (synopsis "AOD ACPI table of the ASUS Adol Book Air 14, fixed to load")
    (description
     "SSDT10 of the laptop's firmware with the two root names that collide
with the DSDT's @code{ASMI} and @code{ISMI} methods deleted, so that ACPICA
can create @code{\\AOD.PSMI} and loading the table no longer panics
@code{acpi_init}.  It is applied through the kernel's initrd ACPI table
override; see @code{asus-adolbook-air14-acpi-hack} in @code{(uraj hardware
asus)}.")
    (license (fsdg-compatible
              "file://vendor/firmware/asus-adolbook-air14/acpi/README.md"
              "machine firmware table dump; no license granted"))))
