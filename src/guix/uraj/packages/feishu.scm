;;; Feishu (Lark) desktop client.
(define-module (uraj packages feishu)
  #:use-module (gnu packages gnupg)
  #:use-module (gnu packages gtk)
  #:use-module (gnu packages tls)
  #:use-module (gnu packages xdisorg)
  #:use-module (guix download)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (nonguix build-system chromium-binary)
  #:use-module ((nonguix licenses) #:prefix license:))

(define-public feishu
  (package
    (name "feishu")
    (version "7.72.23")
    (source
     (origin
       (method url-fetch)
       ;; www.feishu.cn/api/package_info?platform=10 returns a signed URL that
       ;; expires.  The same artifact is served unsigned under
       ;; sf3-cn.feishucdn.com/obj/, with the lfN-ug-sign host replaced and
       ;; the query string stripped; pin that URL instead.
       (uri (string-append
             "https://sf3-cn.feishucdn.com/obj/ee-appcenter/fc38d53a/"
             "Feishu-linux_x64-" version ".deb"))
       (sha256
        (base32 "04vf56zwvzz9zjkpi08pwgfqkcscns49f2gws3c517z207hlqx3w"))))
    (build-system chromium-binary-build-system)
    (arguments
     (list
      #:strip-binaries? #f
      #:validate-runpath? #f
      ;; Only the launcher needs a shebang patch; the bundle contains many
      ;; unrelated scripts whose interpreters are not our concern.
      #:patch-shebangs? #f
      #:modules
      '((nonguix build chromium-binary-build-system)
        (guix build utils))
      #:install-plan
      #~'(("opt/bytedance/feishu/" "opt/bytedance/feishu/")
          ("usr/share/" "share/"))
      #:phases
      #~(modify-phases %standard-phases
          (delete 'patch-source-shebangs)
          ;; The upstream launcher already points LD_LIBRARY_PATH at the
          ;; bundle, so the chromium wrapper only adds environment that
          ;; Electron then leaks into its children.  Skip it and let the
          ;; RPATH patched below resolve Guix libraries.
          (delete 'install-wrapper)
          (add-after 'binary-unpack 'patch-launcher
            (lambda* (#:key inputs #:allow-other-keys)
              (substitute* "opt/bytedance/feishu/bytedance-feishu"
                (("^#!/bin/bash")
                 (string-append
                  "#!" (assoc-ref inputs "bash-minimal") "/bin/bash")))))
          (replace 'patchelf
            (lambda* (#:key inputs #:allow-other-keys)
              (define (input-lib-directories)
                (map (lambda (input)
                       (string-append (cdr input) "/lib"))
                     (filter (lambda (input)
                               (and (not (member (car input)
                                                 '("libc32" "source")))
                                    (file-exists?
                                     (string-append (cdr input) "/lib"))))
                             inputs)))
              (let* ((nss (assoc-ref inputs "nss"))
                     (interpreter
                      (car (find-files (assoc-ref inputs "libc")
                                       "ld-linux.*\\.so")))
                     ;; Keep $ORIGIN so the bundle's own libraries are found
                     ;; when one of them is started or dlopened directly.
                     (rpath (string-join
                             (append (list "$ORIGIN"
                                           (string-append nss "/lib/nss"))
                                     (input-lib-directories))
                             ":")))
                (for-each
                 (lambda (file)
                   (unless (string-contains file ".so")
                     (invoke "patchelf" "--set-interpreter" interpreter
                             file))
                   (invoke "patchelf" "--set-rpath" rpath file))
                 (find-files "opt/bytedance/feishu"
                             (lambda (file stat)
                               (and (eq? 'regular (stat:type stat))
                                    (elf-file? file))))))))
          (add-after 'install 'install-launchers
            (lambda* (#:key inputs #:allow-other-keys)
              (let* ((bin (string-append #$output "/bin"))
                     (real (string-append #$output
                                          "/opt/bytedance/feishu/bytedance-feishu"))
                     (wrapper (string-append bin "/feishu"))
                     (bash (assoc-ref inputs "bash-minimal"))
                     (nss-lib (string-append (assoc-ref inputs "nss")
                                             "/lib/nss")))
                (mkdir-p bin)
                (symlink real (string-append bin "/bytedance-feishu"))
                ;; WaylandFractionalScaleV1 makes Chromium compute
                ;; surface/input geometry at the wrong scale on niri
                ;; (niri#2770); without it integer buffer scales keep
                ;; clicks aligned on fractionally scaled outputs.
                (call-with-output-file wrapper
                  (lambda (port)
                    (display
                     (string-append
                      "#!" bash "/bin/bash\n"
                      "set -eu\n"
                      ;; Chromium locates libnssckbi.so, the NSS
                      ;; built-in public root module, through
                      ;; LD_LIBRARY_PATH.  Without this the native
                      ;; network stack rejects every public
                      ;; certificate and the client reports that it
                      ;; has no internet connection.
                      "export LD_LIBRARY_PATH=\""
                      nss-lib
                      "${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}\"\n"
                      "flags=()\n"
                      "if [ -n \"${WAYLAND_DISPLAY:-}\" ]; then\n"
                      "  flags+=(--ozone-platform=wayland\n"
                      "          --disable-features=WaylandFractionalScaleV1\n"
                      "          --enable-wayland-ime\n"
                      "          --wayland-text-input-version=3)\n"
                      "fi\n"
                      "exec \"" real "\" \"${flags[@]}\" \"$@\"\n")
                     port)))
                (chmod wrapper #o755))))
          (add-after 'install 'patch-desktop-entry
            (lambda _
              (substitute* (string-append
                            #$output
                            "/share/applications/bytedance-feishu.desktop")
                (("Exec=/usr/bin/bytedance-feishu-stable")
                 (string-append "Exec=" #$output "/bin/feishu")))))
          (add-after 'install 'install-icons
            (lambda _
              (let ((icons (string-append #$output "/share/icons/hicolor")))
                (for-each
                 (lambda (size)
                   (let ((directory
                          (string-append icons "/" size "x" size "/apps")))
                     (mkdir-p directory)
                     (symlink (string-append
                               #$output "/opt/bytedance/feishu/product_logo_"
                               size ".png")
                              (string-append directory
                                             "/bytedance-feishu.png"))))
                 '("16" "24" "32" "48" "64" "128" "256"))))))))
    (inputs
     (list gdk-pixbuf gnutls libgcrypt pixman))
    (supported-systems '("x86_64-linux"))
    (home-page "https://www.feishu.cn/")
    (synopsis "Feishu (Lark) collaboration suite")
    (description
     "Feishu, also known as Lark outside China, is an all-in-one collaboration
suite with messaging, calendars, video meetings and collaborative documents.
This package repackages ByteDance's official Linux x64 Debian package; updates
are managed through Guix.  The launcher enables native Wayland, the Wayland
input method and integer buffer scaling, and falls back to XWayland when
@env{WAYLAND_DISPLAY} is unset.")
    (license (license:nonfree "https://www.feishu.cn/en/terms"))))
