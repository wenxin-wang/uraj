(define-module (uraj home emacs)
  #:use-module (gnu home)
  #:use-module (gnu home services)
  #:use-module (gnu packages)
  #:use-module (gnu services)
  #:use-module (guix gexp)
  #:use-module (uraj utils file path)
  #:export (emacs-home-services))

(define (emacs-packages)
  (specifications->packages
    '("emacs-pgtk"
      "gcc-toolchain"
      ;; Lisp packages are managed here by default.  embark includes
      ;; embark-consult; built-in libraries need no separate package.
      "emacs-straight"
      "emacs-no-littering"
      "emacs-el-patch"
      "emacs-blackout"
      "emacs-repeat-fu"
      "emacs-undo-tree"
      "emacs-ace-window"
      "emacs-meow"
      "emacs-avy"
      "emacs-smartparens"
      "emacs-corfu"
      "emacs-cape"
      "emacs-vertico"
      "emacs-orderless"
      "emacs-marginalia"
      "emacs-embark"
      "emacs-consult"
      "emacs-dirvish"
      "emacs-magit"
      "emacs-diff-hl"
      "emacs-with-editor"
      "emacs-org-journal"
      "emacs-org-roam"
      "emacs-dumb-jump"
      "emacs-treesit-auto"
      "emacs-flycheck"
      "emacs-lsp-mode"
      "emacs-lsp-ui"
      "emacs-jsonnet-mode"
      "emacs-google-c-style"
      "emacs-dtrt-indent"
      "emacs-apheleia"
      "emacs-nix-mode"
      "emacs-bazel"
      "emacs-gptel"
      "emacs-ob-gptel"
      "emacs-agent-shell"
      "emacs-claude-code-ide"
      "emacs-compile-angel"
      "emacs-modus-themes"
      "emacs-nerd-icons-completion"
      "emacs-nerd-icons-corfu"
      "emacs-doom-modeline"
      "emacs-popper"
      ;; Dependencies of the remaining straight packages, where Guix has them.
      ;; Other shared dependencies arrive through propagated-inputs.
      "emacs-aio"
      "emacs-request"
      "emacs-polymode"
      "emacs-shell-maker"
      "emacs-mcp"
      "emacs-track-changes"
      "emacs-plz-media-type"
      "emacs-plz-event-source"
      ;; Keep the Lisp frontend and its compiled epdfinfo server together.
      ;; post-init.el opts out of straight for this package.
      "emacs-pdf-tools"
      ;; Guix's Emacs finds these via TREE_SITTER_GRAMMAR_PATH.  These are
      ;; grammars for builtin treesit, not the older emacs-tree-sitter package.
      "tree-sitter-bash"
      "tree-sitter-c"
      "tree-sitter-cpp"
      "tree-sitter-c-sharp"
      "tree-sitter-cmake"
      "tree-sitter-css"
      "tree-sitter-dockerfile"
      "tree-sitter-elisp"
      "tree-sitter-go"
      "tree-sitter-gomod"
      "tree-sitter-html"
      "tree-sitter-java"
      "tree-sitter-javascript"
      "tree-sitter-json"
      "tree-sitter-jsonnet"
      "tree-sitter-lua"
      "tree-sitter-markdown"           ; includes markdown-inline
      "tree-sitter-nix"
      "tree-sitter-python"
      "tree-sitter-rust"
      "tree-sitter-toml"
      "tree-sitter-typescript"         ; includes TSX
      "tree-sitter-yaml"
      ;; External programs used by lsp-mode, Apheleia, Org and Dired.
      "emacs-lsp-booster"
      "clang"                          ; clangd and clang-format
      "ruff"
      "graphviz"                       ; org-roam-graph
      "imagemagick"                    ; image-dired / Dirvish thumbnails
      "poppler")))                     ; pdftoppm / pdftotext previews

(define minimal-emacs-repository
  "https://github.com/jamescherti/minimal-emacs.d")

(define (emacs-config-activation-service)
  (let ((git (file-append (specification->package "git") "/bin/git"))
        (overlay-directory (project-path "env/emacs")))
    (simple-service
     'emacs-config
     home-activation-service-type
     #~(begin
         ;; (ice-9 ftw) is built into Guile; no host module copy is needed.
         (use-modules (ice-9 ftw))

         (define (ensure-directory path)
           (let ((path-stat (false-if-exception (stat path))))
             (cond
              ((not path-stat)
               (mkdir path))
              ((not (eq? 'directory (stat:type path-stat)))
               (error "expected a directory" path)))))

         (define (ensure-symlink source target)
           (let ((target-stat (false-if-exception (lstat target))))
             (cond
              ((not target-stat)
               (symlink source target))
              ((and (eq? 'symlink (stat:type target-stat))
                    (string=? (readlink target) source)))
              ((eq? 'symlink (stat:type target-stat))
               (delete-file target)
               (symlink source target))
              (else
               (error "refusing to replace non-symlink Emacs config"
                      target)))))

         (define (link-regular-files source-directory target-directory)
           (ensure-directory target-directory)
           (for-each
            (lambda (name)
              (let* ((source (string-append source-directory "/" name))
                     (target (string-append target-directory "/" name))
                     (source-type (stat:type (lstat source))))
                (cond
                 ((eq? source-type 'directory)
                  (link-regular-files source target))
                 ((eq? source-type 'regular)
                  (ensure-symlink source target)))))
            (scandir source-directory
                     (lambda (name)
                       (not (member name '("." "..")))))))

         (when (file-exists? #$overlay-directory)
           (let* ((home (getenv "HOME"))
                  (config-home (string-append home "/.config"))
                  (emacs-home (string-append config-home "/emacs")))
             (ensure-directory config-home)
             (unless (file-exists? emacs-home)
               (unless (zero? (system* #$git "clone"
                                       #$minimal-emacs-repository
                                       emacs-home))
                 (error "failed to clone minimal-emacs.d")))
             (link-regular-files #$overlay-directory emacs-home)))))))

(define (emacs-home-services)
  (list
   (simple-service 'emacs-packages
                   home-profile-service-type
                   (emacs-packages))
   (emacs-config-activation-service)))
