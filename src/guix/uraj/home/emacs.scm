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
      ;; Pure Elisp packages are managed by straight in post-init.el.  Guix
      ;; only supplies packages with native parts and external programs.
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
      "ruff"                           ; Apheleia formatting / Flycheck lint
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
