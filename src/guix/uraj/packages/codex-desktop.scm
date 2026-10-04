(define-module (uraj packages codex-desktop)
  #:use-module (gnu packages hardware)
  #:use-module (gnu packages libusb)
  #:use-module (gnu packages tls)
  #:use-module (gnu packages version-control)
  #:use-module (guix download)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (nonguix build-system chromium-binary)
  #:use-module ((nonguix licenses) #:prefix license:))

(define-public codex-desktop
  (package
    (name "codex-desktop")
    (version "26.930.41038")
    (source
     (origin
       (method url-fetch)
       (uri (string-append
             "https://persistent.oaistatic.com/codex-app-prod/linux/deb/"
             "pool/main/c/chatgpt/chatgpt_" version "_amd64.deb"))
       (sha256
        (base32 "0z549nb0yvkx16n4fgx9lh5ixfpn8iys67nh75r8swalala58y7f"))))
    (build-system chromium-binary-build-system)
    (arguments
     (list
      #:strip-binaries? #f
      ;; The bundle also contains optional Qt shims and native modules for
      ;; other platforms.  Use the default GTK UI and patch only Linux x64
      ;; glibc binaries; the bundled Codex tools are statically linked.
      #:validate-runpath? #f
      #:modules
      '((nonguix build chromium-binary-build-system)
        (guix build utils)
        (nonguix build utils)
        (ice-9 popen)
        (ice-9 textual-ports))
      #:install-plan
      #~'(("usr/lib/chatgpt/" "lib/chatgpt/")
          ("usr/share/applications/" "share/applications/")
          ("usr/share/pixmaps/" "share/pixmaps/")
          ("usr/share/metainfo/" "share/metainfo/")
          ("usr/share/doc/chatgpt/" "share/doc/codex-desktop/"))
      #:phases
      #~(modify-phases %standard-phases
          (replace 'patchelf
            (lambda* (#:key inputs outputs #:allow-other-keys)
              ;; Discover binaries after unpack, and preserve upstream's
              ;; relative RPATHs (in particular sharp's bundled libvips).
              (define files
                (filter
                 (lambda (file)
                   (not (or (member (basename file)
                                    '("codex" "codex-code-mode-host" "rg"
                                      "tectonic" "node_repl"
                                      "libqt5_shim.so" "libqt6_shim.so"))
                            (string-contains file "musl")
                            (string-contains file "linux-arm")
                            (string-contains file "android-"))))
                 (find-files "usr/lib/chatgpt"
                             (lambda (file stat) (elf-file? file)))))
              (define original-rpaths
                (map (lambda (file)
                       (let* ((pipe (open-pipe* OPEN_READ "patchelf"
                                                "--print-rpath" file))
                              (rpath (string-trim-right (get-string-all pipe))))
                         (unless (zero? (close-pipe pipe))
                           (error "Cannot read RPATH" file))
                         (cons file rpath)))
                     files))
              (define libraries
                (map car
                     (filter (lambda (input)
                               (and (not (string=? (car input) "libc32"))
                                    (file-exists?
                                     (string-append (cdr input) "/lib"))))
                             inputs)))
              ((@@ (nonguix build binary-build-system) patchelf)
               #:inputs inputs #:outputs outputs
               #:patchelf-plan
               (map (lambda (file)
                      (list file (cons '("nss" "/lib/nss") libraries)))
                    files))
              (for-each
               (lambda (entry)
                 (invoke "patchelf" "--add-rpath"
                         (if (string-null? (cdr entry))
                             "$ORIGIN"
                             (string-append "$ORIGIN:" (cdr entry)))
                         (car entry)))
               original-rpaths)))
          (add-before 'install 'patch-desktop-entry
            (lambda _
              (substitute* "usr/share/applications/chatgpt.desktop"
                (("Exec=chatgpt")
                 (string-append "Exec=" #$output "/bin/chatgpt")))))
          (add-before 'install-wrapper 'install-launcher
            (lambda _
              (let ((bin (string-append #$output "/bin")))
                (mkdir-p bin)
                (symlink (string-append #$output "/lib/chatgpt/codex-launcher")
                         (string-append bin "/chatgpt")))))
          (add-after 'install-wrapper 'install-codex-desktop-alias
            (lambda _
              ;; Leave the separate Codex CLI's bin/codex unshadowed.
              (symlink "chatgpt"
                       (string-append #$output "/bin/codex-desktop")))))))
    (inputs (list git-minimal libusb openssl tpm2-tss))
    (supported-systems '("x86_64-linux"))
    (home-page "https://developers.openai.com/codex/app")
    (synopsis "Official OpenAI desktop application with Codex")
    (description
     "This package repackages OpenAI's official Linux desktop application,
now distributed as ChatGPT, with its bundled Codex backend, Code Mode host,
terminal and browser tools.  Launch it with @command{codex-desktop} or
@command{chatgpt}.  Updates are managed through Guix.")
    (license (license:nonfree "https://openai.com/policies/terms-of-use/"))))
