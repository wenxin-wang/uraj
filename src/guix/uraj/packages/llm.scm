(define-module (uraj packages llm)
  #:use-module (guix download)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module ((px packages ai)
                #:select ((claude-code . pantherx-claude-code)))
  #:use-module ((px packages tools)
                #:select ((codex . pantherx-codex)))
  #:export (claude-code
            codex))

;;; PantherX's package replaces `unpack' and leaves the build-directory root as
;;; the working directory, so install-license-files lists "../" (= /tmp) to
;;; find the source directory.  The host's AppArmor profile for guix-builders
;;; does not allow reading /tmp itself, so scandir returns #f and the phase
;;; dies with `match-error'.  The package installs a single binary and ships
;;; no license files in the build tree, so drop the phase.
(define-public claude-code
  (package
    (inherit pantherx-claude-code)
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
