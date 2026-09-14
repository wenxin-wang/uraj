(define-module (uraj common basic-services)
  #:use-module (gnu home services)
  #:use-module (gnu home services dotfiles)
  #:use-module (gnu services)
  #:use-module (guix gexp)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 regex)
  #:use-module (srfi srfi-1)
  #:export (block-in-file-activation-service
            block-in-files-activation-service
            my-dotfiles-services))

(define (block-template-store-name path)
  ;; Store names must not start with "." nor contain "/" or spaces (see
  ;; 'valid-store-name?' in (guix store)); template file names typically
  ;; start with ".".
  (string-append
   "block-template-"
   (string-map (lambda (chr)
                 (if (and (char-set-contains? char-set:ascii chr)
                          (char-set-contains? char-set:graphic chr)
                          (not (memv chr '(#\. #\/ #\space))))
                     chr
                     #\-))
               path)))

(define (block-template-file template-path)
  "Return a file-like object that snapshots TEMPLATE-PATH into the store at
reconfigure time."
  (local-file template-path
              (block-template-store-name
               (last (string-split template-path #\/)))))

(define* (block-in-file-activation-service template-path target-file-path
                                           #:key (comment-str "#")
                                           (name 'block-in-file-activation))
  "Return a home activation service that makes sure TARGET-FILE-PATH contains
a block generated from TEMPLATE-PATH, delimited by
\"COMMENT-STR BEGIN-BLOCK: TEMPLATE-PATH\" and
\"COMMENT-STR END-BLOCK: TEMPLATE-PATH\".  The template is snapshotted into
the store at reconfigure time, like 'home-dotfiles-service-type' does, so
edits made after reconfigure take effect only after the next reconfigure."
  (simple-service name
                  home-activation-service-type
                  (with-imported-modules '((uraj utils file template))
                    #~(begin
                        (use-modules (uraj utils file template))
                        (ensure-template-block-in-file
                         #$(block-template-file template-path)
                         #$target-file-path
                         #:comment-str #$comment-str
                         #:label #$template-path)))))

(define %block-template-re
  ;; "<x>.block<anything>.tmpl" -> x
  (make-regexp "^(.+)\\.block.*\\.tmpl$"))

(define (block-template-target rel-path)
  "Given REL-PATH, the path of a template relative to a stow dotfiles
directory, return the corresponding path relative to $HOME: the first path
component (the stow package directory) is dropped and the \".block*.tmpl\"
suffix is stripped from the file name.  Return #f when REL-PATH does not name
a block template."
  (let* ((components (string-split rel-path #\/))
         (base (last components))
         (m (regexp-exec %block-template-re base)))
    (and m
         (string-join
          (append (drop-right (cdr components) 1)
                  (list (match:substring m 1)))
          "/"))))

(define (find-block-templates dir)
  "Return the list of (TEMPLATE-PATH . TARGET-RELATIVE-PATH) pairs for all the
\"*.block*.tmpl\" files under DIR."
  (define prefix-length (string-length dir))
  (file-system-fold
   (lambda (path stat result) #t)          ; enter?
   (lambda (path stat result)              ; leaf
     (if (and (string-prefix? dir path)
              (> (string-length path) prefix-length))
         (let ((target (block-template-target
                        (substring path (1+ prefix-length)))))
           (if target
               (cons (cons path target) result)
               result))
         result))
   (lambda (path stat result) result)      ; down
   (lambda (path stat result) result)      ; up
   (lambda (path stat result) result)      ; skip
   (lambda (path stat errno result) result) ; error
   '()
   dir))

(define* (block-in-files-activation-service dotfiles-dir
                                            #:key (comment-str "#")
                                            (name 'block-in-file-activation))
  "Return a home activation service that makes sure every \"*.block*.tmpl\"
template found under DOTFILES-DIR (a stow layout) is added to the
corresponding file under $HOME.  Template contents are snapshotted into the
store at reconfigure time, like 'home-dotfiles-service-type' does, so edits
made after reconfigure take effect only after the next reconfigure."
  (let ((templates (find-block-templates dotfiles-dir)))
    (simple-service name
                    home-activation-service-type
                    (with-imported-modules '((uraj utils file template))
                      #~(begin
                          (use-modules (uraj utils file template))
                          #$@(map (lambda (template)
                                    (let ((template-path (car template))
                                          (target-rel-path (cdr template)))
                                      #~(ensure-template-block-in-file
                                         #$(block-template-file template-path)
                                         (string-append (getenv "HOME") "/"
                                                        #$target-rel-path)
                                         #:comment-str #$comment-str
                                         #:label #$template-path)))
                                  templates))))))

(define (my-dotfiles-services source-directories)
  "Return a list of services that stow dotfiles from SOURCE-DIRECTORIES (a
list of stow-layout dotfiles directories) into $HOME and activate the
\"*.block*.tmpl\" templates found within them."
  (append
   (map block-in-files-activation-service source-directories)
   (list (service home-dotfiles-service-type
           (home-dotfiles-configuration
            (directories source-directories)
            (layout 'stow)
            (excluded (cons "\\.tmpl$"
                            (home-dotfiles-configuration-excluded
                             (home-dotfiles-configuration)))))))))
