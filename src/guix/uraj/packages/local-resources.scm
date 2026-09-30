;;; local-resources.scm -- packages built from resources of the machine
;;; the configuration is evaluated on (certificates provisioned outside
;;; Guix, etc.).

(define-module (uraj packages local-resources)
  #:use-module (gnu home services)
  #:use-module (gnu packages nss)
  #:use-module (gnu packages tls)
  #:use-module (gnu services)
  #:use-module (guix build-system trivial)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:export (local-ca-certificates-directory
            local-ca-certificates-available?
            local-ca-certs
            firefox-local-ca-certs-service))

;; Where the company's provisioning drops extra CA certificates on
;; managed hosts; the host's update-ca-certificates merges them into
;; /etc/ssl/certs, which Guix programs do not read.
(define local-ca-certificates-directory
  "/usr/local/share/ca-certificates")

(define (local-ca-certificates-available?)
  "Return #t when this machine has extra CA certificates in
@code{local-ca-certificates-directory}."
  (file-exists? local-ca-certificates-directory))

;;; The package exists so that the profile's own certificate bundle
;;; trusts the corporate PKI: the 'ca-certificate-bundle' profile hook
;;; (guix/profiles.scm) concatenates the *.pem files found in
;;; etc/ssl/certs of every package in the profile into
;;; $PROFILE/etc/ssl/certs/ca-certificates.crt -- the file
;;; GIT_SSL_CAINFO and friends point at.  nss-certs fills that bundle
;;; with the Mozilla set only, so services under a private PKI fail
;;; certificate verification in every Guix program reading the bundle.
;;;
;;; The certificates are read from the machine when this package is
;;; built, so it must only be instantiated where the directory exists
;;; (see 'local-ca-certificates-available?' and env/guix/os/home.scm);
;;; a new provisioning re-run is picked up by the next reconfigure.
(define local-ca-certs
  (package
    (name "local-ca-certs")
    (version "0")
    (source #f)
    (build-system trivial-build-system)
    (arguments
     (list
      #:builder
      (with-imported-modules '((guix build utils))
        #~(begin
            (use-modules (guix build utils))
            (define certs-dir (string-append #$output "/etc/ssl/certs"))
            (mkdir-p certs-dir)
            ;; Renamed to *.pem: the profile hook above keys on that
            ;; suffix.
            (for-each
             (lambda (cert)
               (copy-file cert
                          (string-append certs-dir "/"
                                         (string-drop-right
                                          (basename cert) 4)
                                         ".pem")))
             (find-files #$(local-file local-ca-certificates-directory
                                       #:recursive? #t)
                         "\\.crt$"))
            ;; Subject-hash symlinks, so the directory also works as an
            ;; SSL_CERT_DIR.
            (invoke (string-append #$(this-package-native-input "openssl")
                                   "/bin/openssl")
                    "rehash" certs-dir)))))
    (native-inputs (list openssl))
    (synopsis "Extra CA certificates provisioned on the local machine")
    (description
     "This package exports the CA certificates of
@file{/usr/local/share/ca-certificates} -- populated by the corporate
provisioning on managed hosts -- as an @file{etc/ssl/certs} directory,
so that the Guix profile's certificate bundle and search paths trust
the corporate PKI.")
    (home-page #f)
    (license #f)))

;;; Firefox ignores the profile's certificate bundle above (that one is
;;; for GnuTLS/OpenSSL programs such as git) and every system-wide trust
;;; store: it keeps a per-profile NSS database (cert9.db) and consults
;;; nothing else, so corporate sites keep showing certificate warnings
;;; (and cert_override.txt workarounds accumulate) unless the
;;; certificates are imported into each profile with NSS' own certutil.
;;;
;;; The activation below does that at reconfigure time for every earlier
;;; profile (both the legacy ~/.mozilla/firefox and the XDG
;;; ~/.config/mozilla/firefox locations); a profile first created after
;;; the last reconfigure is picked up by the next one.  Each certificate
;;; is added as a trusted SSL anchor (trust flags C,,), matching what
;;; the host's update-ca-certificates do with the same files -- they too
;;; treat every file in the directory as an anchor.  Certificates are
;;; looked up by nickname (file name, numbered for multi-certificate
;;; files), so re-running is cheap and adding a file is enough to trust
;;; it; renaming a file would leave the old entry behind, which this
;;; deliberately does not try to garbage-collect.  Byte-identical
;;; duplicates -- the provisioning ships a few certificates under
;;; several file names -- are imported once, under the first file name
;;; seen: NSS keys certificates by issuer and serial, so the extra
;;; copies would only ever be silent no-ops.
(define (firefox-local-ca-certs-service)
  "Return a Home activation service that imports the certificates from
@code{local-ca-certificates-directory} into the NSS databases of all
Firefox profiles found on this machine (see the comment above for why
this is needed in addition to @code{local-ca-certs}).

Import failures -- e.g. a profile whose database is locked by a running
Firefox, even though certutil usually can write anyway -- only print a
warning and never fail the activation; reconfiguring again retries."
  (simple-service 'firefox-local-ca-certs
                  home-activation-service-type
                  (with-imported-modules '((guix build utils))
                    #~(begin
                        (use-modules (guix build utils)
                                     (ice-9 popen)
                                     (ice-9 textual-ports)
                                     (srfi srfi-1)
                                     (srfi srfi-13))

                        (define certutil
                          (string-append #$nss:bin "/certutil"))
                        (define cert-directory
                          #$local-ca-certificates-directory)
                        (define home (getenv "HOME"))
                        (define temp-directory
                          (string-append
                           (or (getenv "XDG_RUNTIME_DIR") "/tmp")
                           "/uraj-firefox-certs-"
                           (number->string (getpid))))

                        (define (profile-directories)
                          "Return the directories of all Firefox profiles
(directories containing a cert9.db) found in the legacy and XDG
config locations."
                          (append-map
                           (lambda (root)
                             (if (file-exists? root)
                                 (map (lambda (entry)
                                        (string-append root "/" entry))
                                      (scandir
                                       root
                                       (lambda (entry)
                                         (file-exists?
                                          (string-append root "/" entry
                                                         "/cert9.db")))))
                                 '()))
                           (list (string-append home "/.mozilla/firefox")
                                 (string-append home
                                                "/.config/mozilla/firefox"))))

                        (define (certificate-blocks file)
                          "Return the list of PEM certificate blocks in
FILE (a provisioned file may hold several)."
                          (call-with-input-file file
                            (lambda (port)
                              (let loop ((line (get-line port))
                                         (block '())
                                         (blocks '()))
                                (cond
                                 ((eof-object? line)
                                  (reverse! blocks))
                                 ((string-prefix?
                                   "-----BEGIN CERTIFICATE-----" line)
                                  (loop (get-line port) (list line) blocks))
                                 ((string-prefix?
                                   "-----END CERTIFICATE-----" line)
                                  (loop (get-line port) '()
                                        (cons (string-join
                                               (reverse! (cons line block))
                                               "\n")
                                              blocks)))
                                 ((null? block)
                                  (loop (get-line port) block blocks))
                                 (else
                                  (loop (get-line port)
                                        (cons line block) blocks)))))))

                        (define nickname-prefix "local-ca-")

                        (define (nickname file index total)
                          "Return the nickname under which to store the
INDEX-th of TOTAL certificates of FILE."
                          (string-append nickname-prefix
                                         (basename file ".crt")
                                         (if (= total 1)
                                             ""
                                             (format #f "-~a" index))))

                        (define (imported-nicknames profile)
                          "Return the nicknames this service has already
imported into PROFILE's NSS database."
                          (let* ((pipe (open-pipe*
                                        OPEN_READ certutil
                                        "-L" "-d" (string-append "sql:" profile)))
                                 (output (get-string-all pipe)))
                            (close-pipe pipe)
                            (filter-map
                             (lambda (line)
                               (and (string-prefix? nickname-prefix line)
                                    (car (string-tokenize line))))
                             (string-split output #\newline))))

                        (define (import-certificate profile nickname block)
                          (let ((file
                                 (string-append
                                  temp-directory "/"
                                  (string-map (lambda (chr)
                                                (if (char=? chr #\/)
                                                    #\_
                                                    chr))
                                              nickname)
                                  ".pem")))
                            (call-with-output-file file
                              (lambda (port)
                                (display block port)
                                (newline port)))
                            (invoke certutil
                                    "-A"
                                    "-d" (string-append "sql:" profile)
                                    "-n" nickname
                                    "-t" "C,,"
                                    "-i" file)))

                        (let ((profiles (profile-directories))
                              (certs (if (file-exists? cert-directory)
                                         (scandir cert-directory
                                                  (lambda (file)
                                                    (string-suffix? ".crt"
                                                                    file)))
                                         '())))
                          (when (and (pair? profiles) (pair? certs))
                            (mkdir-p temp-directory)
                            (let ((imported
                                   (map (lambda (profile)
                                          (cons
                                           profile
                                           (catch #t
                                             (lambda ()
                                               (imported-nicknames profile))
                                             (lambda (key . args)
                                               (format
                                                (current-error-port)
                                                "warning: could not read the \
certificate database of the Firefox profile ~a: ~a~%"
                                                profile key)
                                               '()))))
                                        profiles))
                                  ;; See the comment above: drop
                                  ;; byte-identical copies of a
                                  ;; certificate handled earlier in this
                                  ;; run, so NSS never sees a second copy
                                  ;; under a nickname of its own.
                                  (seen '()))
                              (for-each
                               (lambda (name)
                                 (let* ((file (string-append cert-directory
                                                             "/" name))
                                        (blocks (certificate-blocks file))
                                        (total (length blocks)))
                                   (for-each
                                    (lambda (index+block)
                                      (let ((nickname (nickname file
                                                                (car index+block)
                                                                total))
                                            (block (cdr index+block)))
                                        (unless (member block seen)
                                          (set! seen (cons block seen))
                                          (for-each
                                           (lambda (profile)
                                             (unless
                                                 (member
                                                  nickname
                                                  (cdr (assoc profile
                                                              imported)))
                                               (catch #t
                                                 (lambda ()
                                                   (import-certificate
                                                    profile nickname block))
                                                 (lambda (key . args)
                                                   (format
                                                    (current-error-port)
                                                    "warning: could not \
import ~a into the Firefox profile ~a: ~a~%"
                                                    nickname profile key)))))
                                           profiles))))
                                    (map cons (iota total 1) blocks))))
                               certs))
                            (false-if-exception
                             (delete-file-recursively temp-directory))))))))
