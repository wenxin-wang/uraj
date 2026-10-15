;;; Android client tools.
(define-module (uraj packages android)
  #:use-module (guix build-system trivial)
  #:use-module (guix download)
  #:use-module (guix gexp)
  #:use-module ((nonguix licenses) #:prefix license:)
  #:use-module (guix packages)
  #:use-module (gnu packages base)
  #:use-module (gnu packages compression)
  #:use-module (gnu packages elf)
  #:use-module (gnu packages gcc)
  #:export (android-platform-tools))

;; Google's prebuilt platform-tools.  Guix's own adb (7.1.2) aborts with
;; "free(): invalid pointer" when it starts its server.
(define android-platform-tools
  (package
    (name "android-platform-tools")
    (version "36.0.0")
    (source (origin
              (method url-fetch)
              (uri (string-append
                    "https://dl.google.com/android/repository/platform-tools_r"
                    version "-linux.zip"))
              (sha256
               (base32
                "1s7vrckwnv1zappfybnz8d7wxi393igqzjnc3xq7kzizjhn69b8f"))))
    (build-system trivial-build-system)
    (arguments
     (list
      #:modules '((guix build utils))
      #:builder
      #~(begin
          (use-modules (guix build utils) (ice-9 ftw))
          (let* ((out #$output)
                 ;; Kept as one tree: tools find lib64/ and mke2fs.conf
                 ;; next to themselves.
                 (tree (string-append out "/libexec/platform-tools"))
                 (bin (string-append out "/bin"))
                 (patchelf #$(file-append patchelf "/bin/patchelf"))
                 (rpath (string-append #$glibc "/lib:" #$gcc:lib "/lib:"
                                       tree "/lib64")))
            (invoke #$(file-append unzip "/bin/unzip") "-q" #$source
                    "-d" (getenv "TMPDIR"))
            (copy-recursively (string-append (getenv "TMPDIR")
                                             "/platform-tools")
                              tree)
            (for-each
             (lambda (file)
               (when (elf-file? file)
                 (invoke patchelf "--set-rpath" rpath file)))
             (find-files tree))
            (mkdir-p bin)
            (for-each
             (lambda (name)
               (let ((file (string-append tree "/" name)))
                 (when (and (elf-file? file) (executable-file? file))
                   (invoke patchelf "--set-interpreter"
                           #$(file-append glibc "/lib/ld-linux-x86-64.so.2")
                           file)
                   (symlink file (string-append bin "/" name)))))
             (scandir tree (lambda (name)
                             (not (member name '("." ".."))))))))))
    (native-inputs (list patchelf unzip))
    (inputs (list glibc `(,gcc "lib")))
    (supported-systems '("x86_64-linux"))
    (home-page "https://developer.android.com/tools/releases/platform-tools")
    (synopsis "Android SDK platform tools: adb, fastboot and image tools")
    (description
     "Google's prebuilt Android SDK Platform-Tools, patched to run on Guix:
@command{adb}, @command{fastboot}, @command{mke2fs}, @command{e2fsdroid},
@command{make_f2fs}, @command{sqlite3}, @command{hprof-conv} and
@command{etc1tool}.")
    ;; Android Software Development Kit License; tools are mostly Apache 2.0.
    (license (license:nonfree
              "https://developer.android.com/studio/terms"))))
