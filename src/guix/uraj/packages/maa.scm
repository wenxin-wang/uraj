;;; MAA (MaaAssistantArknights) automation for Arknights.
(define-module (uraj packages maa)
  #:use-module (guix build-system trivial)
  #:use-module (guix download)
  #:use-module (guix gexp)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix packages)
  #:use-module (gnu packages base)
  #:use-module (gnu packages compression)
  #:use-module (gnu packages elf)
  #:use-module (gnu packages gcc)
  #:export (maa-assistant-arknights))

;; Upstream's prebuilt Linux release.  MaaCore links MaaDeps' own builds of
;; OpenCV, onnxruntime and FastDeploy (clang + libc++), which are impractical
;; to build from source here.  The tarball is one flat directory holding
;; libMaaCore.so, its libraries, resource/ and the matching maa-cli
;; executable `maa', which finds MaaCore and resource/ next to itself.
(define maa-assistant-arknights
  (package
    (name "maa-assistant-arknights")
    (version "6.19.0")
    (source (origin
              (method url-fetch)
              (uri (string-append
                    "https://github.com/MaaAssistantArknights/"
                    "MaaAssistantArknights/releases/download/v" version
                    "/MAA-v" version "-linux-x86_64.tar.gz"))
              (sha256
               (base32
                "0md0919gbv8nmpmbafjz217snhlb4f5q6xfkr009jjwjhzakcl4v"))))
    (build-system trivial-build-system)
    (arguments
     (list
      #:modules '((guix build utils))
      #:builder
      #~(begin
          (use-modules (guix build utils) (ice-9 popen) (ice-9 rdelim)
                       (srfi srfi-1))
          (let* ((out #$output)
                 (tree (string-append out "/libexec/maa"))
                 (patchelf #$(file-append patchelf "/bin/patchelf"))
                 (lib-dirs (list tree
                                 (string-append #$glibc "/lib")
                                 (string-append #$gcc:lib "/lib")
                                 (string-append #$zlib "/lib")))
                 (rpath (string-join lib-dirs ":")))
            (define (needed file)
              (let* ((port (open-pipe* OPEN_READ patchelf "--print-needed"
                                       file))
                     (names (let loop ((acc '()))
                              (let ((line (read-line port)))
                                (if (eof-object? line)
                                    (reverse acc)
                                    (loop (cons line acc)))))))
                (close-pipe port)
                names))
            (mkdir-p tree)
            (setenv "PATH" (string-append #$gzip "/bin"))
            (invoke #$(file-append tar "/bin/tar") "-xzf" #$source
                    "-C" tree)
            (for-each
             (lambda (file)
               (when (elf-file? file)
                 (invoke patchelf "--set-rpath" rpath file)
                 ;; Fail here, listing what is missing, rather than at
                 ;; dlopen time on the host.
                 (let ((missing
                        (remove (lambda (name)
                                  (any (lambda (dir)
                                         (file-exists?
                                          (string-append dir "/" name)))
                                       lib-dirs))
                                (needed file))))
                   (unless (null? missing)
                     (error "unresolved libraries" file missing)))))
             ;; resource/ holds Android binaries (minitouch, ...) that are
             ;; pushed to the device; they must stay untouched.
             (find-files tree
                         (let ((resource (string-append tree "/resource/")))
                           (lambda (file stat)
                             (not (string-prefix? resource file))))))
            (let ((maa (string-append tree "/maa")))
              (invoke patchelf "--set-interpreter"
                      #$(file-append glibc "/lib/ld-linux-x86-64.so.2") maa)
              (mkdir-p (string-append out "/bin"))
              ;; maa-cli resolves its own symlink, so MaaCore and
              ;; resource/ are still found in libexec/maa.
              (symlink maa (string-append out "/bin/maa"))
              ;; Loads libMaaCore.so, proving the patched tree runs.
              (setenv "HOME" (getenv "TMPDIR"))
              (invoke maa "version"))))))
    (native-inputs (list gzip patchelf tar))
    (inputs (list glibc `(,gcc "lib") zlib))
    (supported-systems '("x86_64-linux"))
    (home-page "https://maa.plus")
    (synopsis "Arknights assistant with the maa command-line client")
    (description
     "MAA automates daily Arknights tasks (recruitment, base shifts, clues,
credit store, stages) through image recognition over ADB.  This is the
upstream prebuilt MaaCore with its bundled resources and the
@command{maa} command-line client.")
    (license license:agpl3)))
