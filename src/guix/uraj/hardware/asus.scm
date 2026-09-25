(define-module (uraj hardware asus)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (guix modules)
  #:use-module (uraj packages asus)
  #:export (asus-adolbook-air14-acpi-hack
            %asus-adolbook-air14-kernel-cmdlines
            %asus-adolbook-air14-panel-replay-service))

(define %asus-adolbook-air14-kernel-cmdlines
  (list
   ;; Stability mitigations found while running the live
   ;; ISO off the USB stick (see desktop-iso.scm): keep
   ;; the hardware out of its aggressive power states.
   "usbcore.autosuspend=-1"
   "nvme_core.default_ps_max_latency_us=0"
   "pcie_aspm=off"
   ;; DC_DISABLE_PSR | DC_DISABLE_REPLAY.  Do this before
   ;; amdgpu probes so screen-off/on and suspend/resume cannot
   ;; re-enable the panel features disabled by the debugfs
   ;; workaround in (uraj hardware asus).
   "amdgpu.dcdebugmask=0x410"))

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

;;; amdgpu brings up Panel Replay on this machine's internal eDP panel,
;;; and the panel then stops showing updates: the kernel keeps drawing
;;; (fbcon writes reach /dev/fb0, atomic commits keep flowing) while the
;;; physical display freezes on the frame rendered when amdgpu loaded --
;;; appearing as a boot hang or a dead keyboard, most visibly right
;;; after the driver takes over the console.  Writing 1 to the
;;; connector's disallow_edp_enter_replay knob clears replay_supported,
;;; and a blank/unblank of the fbdev then makes the display core
;;; re-evaluate the link and fall back to plain streaming; the same
;;; applies to PSR, which is disabled for good measure.

(define (asus-adolbook-air14-panel-replay-script)
  "Return a script that disables Panel Replay on the eDP connector once
amdgpu is up.  The debugfs knob appears when the driver registers the
connector, so the script polls for it before writing.  (%debug-file-system
in (gnu system file-systems) mounts debugfs at /sys/kernel/debug, so the
script does not need to mount it.)"
  (program-file "asus-adolbook-air14-panel-replay-fix"
    #~(begin
        (define debugfs "/sys/kernel/debug")
        (define replay-knob
          (string-append debugfs "/dri/0/eDP-1/disallow_edp_enter_replay"))
        (define (write-value file value)
          (call-with-output-file file
            (lambda (port)
              (display value port))))
        (define (wait-for-driver)
          (let loop ((tries 0))
            (cond ((file-exists? replay-knob) #t)
                  ((>= tries 90)
                   (format (current-error-port)
                           "asus-adolbook-air14-panel-replay: ~a never appeared~%"
                           replay-knob)
                   #f)
                  (else
                   (sleep 1)
                   (loop (+ tries 1))))))
        ;; The knob appears while amdgpu is still initializing, around
        ;; the driver's first atomic commit to the panel; whether the
        ;; write beats that commit or not, the blank/unblank below makes
        ;; the link fall back to plain streaming, so the panel ends up
        ;; live either way.
        (when (wait-for-driver)
          (write-value replay-knob "1")
          (write-value (string-append debugfs "/dri/0/eDP-1/disallow_edp_enter_psr")
                       "1")
          (write-value "/sys/class/graphics/fb0/blank" "4")
          (sleep 2)
          (write-value "/sys/class/graphics/fb0/blank" "0")))))

;;; A one-shot shepherd service: the script itself polls for the driver,
;;; so no boot ordering requirements are needed.
(define %asus-adolbook-air14-panel-replay-service
  (simple-service 'asus-adolbook-air14-panel-replay
                  shepherd-root-service-type
                  (list (shepherd-service
                         (provision '(asus-adolbook-air14-panel-replay))
                         (one-shot? #t)
                         (start #~(make-forkexec-constructor
                                   (list #$(asus-adolbook-air14-panel-replay-script))))
                         (documentation
                          "Disable Panel Replay on the Adol Book Air 14's eDP
panel, which freezes when replay engages after amdgpu loads.")))))
