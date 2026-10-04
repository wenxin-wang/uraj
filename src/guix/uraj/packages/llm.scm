(define-module (uraj packages llm)
  #:use-module (gnu packages linux)
  #:use-module (guix download)
  #:use-module (guix gexp)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module (nonguix build-system chromium-binary)
  #:use-module ((px packages ai)
                #:select ((claude-code . pantherx-claude-code)))
  #:use-module ((px packages tools)
                #:select ((codex . pantherx-codex)))
  #:export (claude-code
            codex
            paseo))

;;; PantherX's package replaces `unpack' and leaves the build-directory root as
;;; the working directory, so install-license-files lists "../" (= /tmp) to
;;; find the source directory.  The host's AppArmor profile for guix-builders
;;; does not allow reading /tmp itself, so scandir returns #f and the phase
;;; dies with `match-error'.  The package installs a single binary and ships
;;; no license files in the build tree, so drop the phase.
(define-public claude-code
  (package
    (inherit pantherx-claude-code)
    ;; Backport PantherX fd68e7a6's update without advancing the channel lock.
    (version "2.1.287")
    (source
     (origin
       (inherit (package-source pantherx-claude-code))
       (uri (string-append
             "https://storage.googleapis.com/claude-code-dist-"
             "86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/"
             version "/linux-x64/claude"))
       (sha256
        (base32 "1w0q2xd0x9hnkkdmwvbrphigy23l4wjjqf8sd9wgbkq9a6d4h81r"))))
    (arguments
     (substitute-keyword-arguments (package-arguments pantherx-claude-code)
       ((#:phases phases #~%standard-phases)
        #~(modify-phases #$phases
            (delete 'install-license-files)))))))

;;; PantherX installs only the main executable from OpenAI's standalone
;;; release.  Code Mode is distributed as a separate, version-matched host
;;; archive and Codex looks for it next to itself in bin/.
(define-public codex
  (package
    (inherit pantherx-codex)
    (supported-systems '("x86_64-linux"))
    (inputs
     `(("code-mode-host"
        ,(origin
           (method url-fetch)
           (uri (string-append
                 "https://github.com/openai/codex/releases/download/rust-v"
                 (package-version pantherx-codex)
                 "/codex-code-mode-host-x86_64-unknown-linux-musl.tar.gz"))
           (sha256
            (base32
             "1m2lg15awdrv53sq727fh61v3lsklgz6wmwl6w2jgiwzw3mip31j"))))
       ,@(package-inputs pantherx-codex)))
    (arguments
     (substitute-keyword-arguments (package-arguments pantherx-codex)
       ((#:phases phases #~%standard-phases)
        #~(modify-phases #$phases
            ;; The tarball unpacks to a single file, so 'unpack' does not
            ;; enter a sub-directory; see claude-code above for why the
            ;; license phase must go.
            (delete 'install-license-files)
            (add-after 'install 'install-code-mode-host
              (lambda* (#:key inputs outputs #:allow-other-keys)
                (let* ((archive (assoc-ref inputs "code-mode-host"))
                       (host "codex-code-mode-host-x86_64-unknown-linux-musl")
                       (bin (string-append (assoc-ref outputs "out") "/bin")))
                  (invoke "tar" "-xzf" archive host)
                  (install-file host bin)
                  (rename-file (string-append bin "/" host)
                               (string-append bin "/codex-code-mode-host")))))))))))

;;; Like Claude Code, use the official binary distribution.  The Chromium
;;; variant of binary-build-system supplies Electron's runtime dependencies.
(define-public paseo
  (package
    (name "paseo")
    (version "0.10.3")
    (source
     (origin
       (method url-fetch)
       (uri (string-append
             "https://github.com/getpaseo/paseo/releases/download/v" version
             "/Paseo-" version "-amd64.deb"))
       (sha256
        (base32 "00hphr88kkppppwy9x2af54jfvmjzyww85vkqlr3a92mdm6afksa"))))
    (build-system chromium-binary-build-system)
    (arguments
     (list
      #:strip-binaries? #f
      #:validate-runpath? #f
      #:wrapper-plan
      #~(map (lambda (file) (string-append "opt/Paseo/" file))
         ;; Include daemon addons and speech libraries, but not the unused
         ;; musl addons or statically linked esbuild executables.
         '("Paseo.bin"
           "chrome-sandbox"
           "chrome_crashpad_handler"
           "libffmpeg.so"
           "libvulkan.so.1"
           "libvk_swiftshader.so"
           "resources/app.asar.unpacked/node_modules/node-pty/prebuilds/linux-x64/pty.node"
           "resources/app.asar.unpacked/node_modules/@msgpackr-extract/msgpackr-extract-linux-x64/node.abi115.glibc.node"
           "resources/app.asar.unpacked/node_modules/@msgpackr-extract/msgpackr-extract-linux-x64/node.napi.glibc.node"
           "resources/app.asar.unpacked/node_modules/sherpa-onnx-linux-x64/sherpa-onnx.node"
           "resources/app.asar.unpacked/node_modules/sherpa-onnx-linux-x64/libsherpa-onnx-c-api.so"
           "resources/app.asar.unpacked/node_modules/sherpa-onnx-linux-x64/libsherpa-onnx-cxx-api.so"
           "resources/app.asar.unpacked/node_modules/sherpa-onnx-linux-x64/libonnxruntime.so"))
      #:install-plan
      #~'(("opt/Paseo/" "share/paseo/")
          ("usr/share/applications/" "share/applications/")
          ("usr/share/icons/" "share/icons/"))
      #:phases
      #~(modify-phases %standard-phases
          (add-after 'patchelf 'restore-origin-runpath
            (lambda _
              ;; patchelf replaces upstream's $ORIGIN; Electron and sherpa
              ;; still need their co-located shared libraries.
              (for-each
               (lambda (file)
                 (invoke "patchelf" "--add-rpath" "$ORIGIN" file))
               (cons "opt/Paseo/Paseo.bin"
                     (find-files "opt/Paseo/resources/app.asar.unpacked"
                                 "sherpa-onnx.*\\.(node|so)$")))))
          (add-before 'install 'patch-desktop-entry
            (lambda _
              (substitute* "usr/share/applications/Paseo.desktop"
                (("/opt/Paseo/Paseo")
                 (string-append #$output "/bin/paseo-desktop")))))
          (add-before 'install-wrapper 'install-launchers
            (lambda _
              (let ((bin (string-append #$output "/bin"))
                    (app (string-append #$output "/share/paseo")))
                (mkdir-p bin)
                ;; Keep the upstream sandbox launcher, which also handles
                ;; hosts where unprivileged user namespaces are unavailable.
                (symlink (string-append app "/Paseo")
                         (string-append bin "/paseo-desktop"))
                (symlink (string-append app "/resources/bin/paseo")
                         (string-append bin "/paseo"))))))))
    ;; The upstream sandbox launcher probes user namespaces with unshare.
    (inputs (list util-linux))
    (supported-systems '("x86_64-linux"))
    (home-page "https://paseo.sh")
    (synopsis "Desktop interface for AI coding agents")
    (description
     "Paseo provides a desktop interface and a local daemon for managing AI
coding agents such as Claude Code and Codex.  This package repackages the
official Linux desktop application, including its bundled command-line client.
Run @command{paseo-desktop} for the GUI or @command{paseo} for the CLI.")
    (license license:asl2.0)))
