(define-module (uraj packages wireless)
  #:use-module (gnu packages linux)
  #:use-module (gnu packages tls)
  #:use-module (guix build-system linux-module)
  #:use-module (guix download)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:export (wireless-regdb-signed
            mt7921u-linux-module))

;; Nonguix Linux requires a signed regdb.  Guix's wireless-regdb deliberately
;; rebuilds the database without a signature, so retain the upstream pair.
;; The running kernel trusts wens (serial 61C038651AABDCF94BD0AC7FF06C7248DB18C600).
(define wireless-regdb-signed
  (package
    (inherit wireless-regdb)
    (name "wireless-regdb-signed")
    (version "2026.09.03")
    (source
     (origin
       (method url-fetch)
       (uri (string-append
             "https://www.kernel.org/pub/software/network/wireless-regdb/"
             "wireless-regdb-" version ".tar.xz"))
       (sha256
        (base32 "13gmrcsbnkp98b20vqd50d8klxsvl60ydaw0qb8hr0kv480hjbmj"))))
    (native-inputs (list openssl))
    (arguments
     (list
      #:phases
      #~(modify-phases %standard-phases
          (delete 'configure)
          (delete 'build)
          (replace 'check
            (lambda _
              ;; Authenticate the detached signature with the release's
              ;; pinned certificate, rather than any certificate in .p7s.
              ;; Kernel trust was checked separately; -noverify skips the
              ;; unrelated Web-PKI certificate-chain validation here.
              (invoke "openssl" "cms" "-verify" "-binary" "-inform" "DER"
                      "-in" "regulatory.db.p7s" "-content" "regulatory.db"
                      "-certfile" "wens.x509.pem" "-nointern" "-noverify"
                      "-out" "/dev/null")))
          (replace 'install
            (lambda _
              (let ((firmware (string-append #$output "/lib/firmware")))
                (install-file "regulatory.db" firmware)
                (install-file "regulatory.db.p7s" firmware)))))))))

;; Nonguix enables CONFIG_MT7921E (PCIe) on top of Guix's kernel
;; configuration but not CONFIG_MT7921U, so USB MT7921 adapters
;; (0e8d:7961) have no driver.  Rather than rebuilding the whole kernel,
;; build only mt7921u.ko from LINUX's own source tree: mt7921-common,
;; mt792x-usb and mt76-usb, whose symbols it uses, are already modules
;; of LINUX (enabled for MT7921E and MT7925U), and its firmware is in
;; linux-firmware.  Command-line variables override the kernel's
;; configuration in this directory's Kbuild, selecting mt7921u alone so
;; that no in-tree module is duplicated.
(define (mt7921u-linux-module linux)
  (package
    (name "mt7921u-linux-module")
    (version (package-version linux))
    (source (package-source linux))
    (build-system linux-module-build-system)
    (arguments
     (list #:linux linux
           #:tests? #f                  ;no test suite
           #:source-directory "drivers/net/wireless/mediatek/mt76/mt7921"
           #:make-flags #~(list "CONFIG_MT7921U=m"
                                "CONFIG_MT7921_COMMON="
                                "CONFIG_MT7921E="
                                "CONFIG_MT7921S=")))
    (home-page (package-home-page linux))
    (synopsis "Linux driver for USB MediaTek MT7921 Wi-Fi adapters")
    (description "This package provides the @code{mt7921u} kernel module
from Linux's own sources, for kernels configured without it.")
    (license (package-license linux))))
