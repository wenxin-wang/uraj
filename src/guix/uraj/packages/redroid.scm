(define-module (uraj packages redroid)
  #:use-module (guix packages)
  #:use-module (guix gexp)
  #:use-module (guix utils)
  #:use-module (guix build-system copy)
  #:use-module (guix build-system gnu)
  #:use-module (guix git-download)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module ((nonguix licenses) #:prefix nonguix-license:)
  #:use-module (gnu packages base)
  #:export (redroid-init redroid-ndk-translation))

(define redroid-init
  (package
    (name "redroid-init")
    (version "0.1")
    (source (local-file "aux-files/redroid-init.c"))
    (build-system gnu-build-system)
    (inputs (list `(,glibc "static")))
    (arguments
     (list
      #:tests? #f ; Mount/exec behavior requires a privileged Android container.
      #:phases
      #~(modify-phases %standard-phases
          (replace 'unpack
            (lambda* (#:key source #:allow-other-keys)
              (copy-file source "redroid-init.c")))
          (delete 'configure)
          (replace 'build
            (lambda _
              (invoke #$(cc-for-target) "-static" "-Os" "-Wall" "-Wextra"
                      "-Werror" "redroid-init.c" "-o" "redroid-init")))
          (replace 'install
            (lambda _ (install-file "redroid-init" (string-append #$output "/bin")))))))
    (home-page "https://github.com/remote-android/redroid-doc")
    (synopsis "Protect host module loading before starting Android")
    (description "A static entrypoint that makes the modprobe sysctl read-only
inside the container mount namespace, then executes Android init.  It needs
neither Android's not-yet-mounted APEX libraries nor the host GNU store.")
    (license license:gpl3+)))

;; Google's ARM-to-x86 native bridge from ChromeOS guybrush R112 (Android 11
;; ARCVM), as repackaged for Android-x86 builds.  Every installed file matched
;; guybrush 15359.58.0's official ARC system image byte for byte.  redroid 11's own build of
;; it aborts Arknights in Scudo seconds after start.
(define redroid-ndk-translation
  (let ((commit "9324a8914b649b885dad6f2bfd14a67e5d1520bf")
        (revision "0"))
    (package
      (name "redroid-ndk-translation")
      (version (git-version "0" revision commit))
      (source (origin
                (method git-fetch)
                (uri (git-reference
                      (url "https://github.com/supremegamers/vendor_google_proprietary_ndk_translation-prebuilt")
                      (commit commit)))
                (file-name (git-file-name name version))
                (sha256
                 (base32
                  "0p7spczqfy4455f4hya4b0n6474xz5grh1px67pn5qhry14b7qzr"))))
      (build-system copy-build-system)
      (arguments
       ;; Only what apps need.  The init script and program runners register
       ;; ARM executables in binfmt_misc, which is not namespaced: it would
       ;; reach the host.
       (list #:install-plan
             #~'(("prebuilts/lib" "system/lib")
                 ("prebuilts/lib64" "system/lib64")
                 ("prebuilts/bin/arm" "system/bin/arm")
                 ("prebuilts/bin/arm64" "system/bin/arm64")
                 ;; cpuinfo.arm*.txt are absent from Google's image.
                 ("prebuilts/etc" "system/etc" #:include-regexp ("/ld\\.config[^/]*$"))
                 ("ARM_TO_AMD_DBT_LICENSE.txt"
                  "share/doc/redroid-ndk-translation/"))))
      (supported-systems '("x86_64-linux"))
      (home-page
       "https://github.com/supremegamers/vendor_google_proprietary_ndk_translation-prebuilt")
      (synopsis "ARM native bridge (libndk_translation) for redroid 11")
      (description "Google's prebuilt ndk_translation, which lets x86_64
Android run ARM apps, laid out as a @file{/system} overlay for a redroid
image.  The binfmt_misc registration for ARM executables is omitted.")
      ;; ARM's license grants use only on AMD CPUs; Google's own terms
      ;; cover the rest.
      (license (nonguix-license:nonfree
                "file://share/doc/redroid-ndk-translation/ARM_TO_AMD_DBT_LICENSE.txt"
                "Use limited to AMD CPUs.")))))
