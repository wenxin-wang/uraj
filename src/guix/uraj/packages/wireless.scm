(define-module (uraj packages wireless)
  #:use-module (gnu packages linux)
  #:use-module (gnu packages tls)
  #:use-module (guix download)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:export (wireless-regdb-signed))

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
