;;; Hardware monitoring drivers.

(define-module (uraj packages hwmon)
  #:use-module (guix build-system linux-module)
  #:use-module (guix gexp)
  #:use-module (guix git-download)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix packages)
  #:export (it87-linux-module))

;; IT8613 infers enable=0 from duty=255, losing an explicit enable=1.
;; Preserve that request per channel for unmodified pwmconfig/fancontrol.
;; Other chips, initial firmware state, enable=0 and enable=2 are unchanged.
(define %it87-manual-mode-patch
  (plain-file "it87-it8613-manual-mode.patch"
    "--- a/it87.c
+++ b/it87.c
@@ -1166,6 +1166,8 @@
 \t */
 \tu8 has_pwm;\t\t/* Bitfield, pwm control enabled */
 \tu8 pwm_ctrl[NUM_PWM];\t/* Register value */
+\t/* Preserve explicit IT8613 manual mode even at full duty. */
+\tu8 it8613_manual_mask;
 \tu8 pwm_duty[NUM_PWM];\t/* Manual PWM value set by user */
 \tu8 pwm_temp_map[NUM_PWM];/* PWM to temp. chan. mapping (bits 1-0) */
 \tu8 pwm_temp_map_mask;\t/* 0x03 for old, 0x07 for new temp map */
@@ -3846,6 +3848,8 @@
 \t\treturn 0;\t\t\t/* Full speed */
 \tif (data->pwm_ctrl[nr] & 0x80)
 \t\treturn 2;\t\t\t/* Automatic mode */
+\tif (data->type == it8613 && (data->it8613_manual_mask & BIT(nr)))
+\t\treturn 1;\t\t\t/* Explicit manual mode */
 \tif ((!has_fanctl_onoff(data) || nr >= 3) &&
 \t    data->pwm_duty[nr] == pwm_to_reg(data, 0xff))
 \t\treturn 0;\t\t\t/* Full speed */
@@ -4216,6 +4220,13 @@
 \t\t}
 \t}
\x20
+\tif (data->type == it8613) {
+\t\tif (val == 1)
+\t\t\tdata->it8613_manual_mask |= BIT(nr);
+\t\telse
+\t\t\tdata->it8613_manual_mask &= ~BIT(nr);
+\t}
+
 \tit87_unlock(data);
 \treturn count;
 }
"))

;; Linux's own it87 driver does not know the IT8613E (storie, hypie);
;; this out-of-tree one does.  Build it against LINUX, the operating
;; system's kernel; Guix handles installation instead of DKMS.
(define (it87-linux-module linux)
  (let ((commit "bc06d3488439e5fcd725c1bdcfcac994d6d95cac"))
    (package
      (name "it87-linux")
      (version (git-version "0" "2" commit))
      (source
       (origin
         (method git-fetch)
         (uri (git-reference
               (url "https://github.com/frankcrawford/it87")
               (commit commit)))
         (file-name (git-file-name name version))
         (sha256
          (base32 "1fga3dmxychrf7m1xjdj51zab682i8rcrfr23565yjv8g6hsi5gh"))))
      (build-system linux-module-build-system)
      (arguments
       (list #:linux linux
             #:tests? #f ; No upstream test suite; hardware test is separate.
             #:phases
             #~(modify-phases %standard-phases
                 (add-after 'unpack 'fix-it8613-manual-mode
                   (lambda _
                     (invoke "patch" "-p1" "--fuzz=0" "-i"
                             #$%it87-manual-mode-patch))))
             #:make-flags #~(list #$(string-append "DRIVER_VERSION=" version)
                                 #$(string-append
                                    "TARGET=" (package-version linux)))))
      (home-page "https://github.com/frankcrawford/it87")
      (synopsis "ITE Super I/O monitoring and fan control driver")
      (description "Out-of-tree it87 driver with support for IT8613E
temperature sensors, fan tachometers and PWM control.")
      (license license:gpl2+))))
